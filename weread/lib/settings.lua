local DataStorage = require("datastorage")
local BookStore = require("weread.lib.book_store")
local Cookie = require("weread.lib.cookie")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings
Settings.AUTH_SCHEMA_VERSION = 1

local defaults = {
    auth_schema_version = Settings.AUTH_SCHEMA_VERSION,
    api_key = "",
    cookies = {},
    wr_ticket = "",
    wr_wrpa = "",
    account = {
        name = "",
        user_vid = "",
        login_method = "",
        login_time = 0,
    },
    books = {},
    sync = {
        pull_on_open = false,
        upload_on_close = false,
        ask_on_conflict = true,
    },
    cache = {
        download_book_images = true,
        download_mp_images = false,
        auto_prefetch_next_chapter = false,
        show_prefetch_notifications = true,
        -- K4 fork: underlines/thoughts feature removed; the corresponding
        -- config keys (download_underlines_and_thoughts, show_annotations,
        -- ignore_edge_thought_taps, edge_tap_ratio) are no longer used.
        max_size_mb = 1024,
    },
    read_report = {
        -- v0.6.0-k4-v2.x: enabled and auto-associate are the defaults for
        -- fresh installs (existing saved configs are untouched — LuaSettings
        -- returns the stored table, not these defaults).
        enabled = true,
        mode = "auto",
        book_id = "",
        book_title = "",
        interval_seconds = 30,
        report_on_open = true,
    },
    shelf = {
        sort_order = "time_desc",
    },
    download_dir = "",
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function ensure_dir(path)
    if not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

local function clear_auth_store(store)
    store:saveSetting("api_key", "")
    store:saveSetting("cookies", {})
    store:saveSetting("wr_ticket", "")
    store:saveSetting("wr_wrpa", "")
    store:saveSetting("account", deepcopy(defaults.account))
end

function Settings:new()
    local data_dir = DataStorage:getFullDataDir() .. "/weread"
    ensure_dir(data_dir)
    local obj = {
        data_dir = data_dir,
        default_cache_dir = data_dir .. "/cache",
        settings_file = DataStorage:getSettingsDir() .. "/weread.lua",
    }
    obj.store = LuaSettings:open(obj.settings_file)
    -- cache_dir is the download root; defaults to <data_dir>/cache unless overridden.
    local download_dir = obj.store:readSetting("download_dir", "")
    obj.cache_dir = (type(download_dir) == "string" and download_dir ~= "") and download_dir or obj.default_cache_dir
    ensure_dir(obj.cache_dir)
    local cache = obj.store:readSetting("cache", deepcopy(defaults.cache))
    local cache_changed = false
    if cache.download_book_images == nil then
        cache.download_book_images = cache.download_images ~= false
        cache_changed = true
    end
    if cache.download_mp_images == nil then
        cache.download_mp_images = false
        cache_changed = true
    end
    if cache.auto_prefetch_next_chapter == nil then
        cache.auto_prefetch_next_chapter = false
        cache_changed = true
    end
    if cache.show_prefetch_notifications == nil then
        cache.show_prefetch_notifications = true
        cache_changed = true
    end
    -- K4 fork: drop legacy underlines/thoughts cache keys from old configs so
    -- they do not linger forever. Safe: no code reads them anymore.
    for _, legacy_key in ipairs({
        "download_underlines_and_thoughts",
        "show_annotations",
        "ignore_edge_thought_taps",
        "edge_tap_ratio",
    }) do
        if cache[legacy_key] ~= nil then
            cache[legacy_key] = nil
            cache_changed = true
        end
    end
    if cache.download_images ~= nil then
        cache.download_images = nil
        cache_changed = true
    end
    if cache_changed then
        obj.store:saveSetting("cache", cache)
        obj.store:flush()
    end
    local legacy_changed = false
    for _, key in ipairs({
        "config_auth_fingerprint",
        "config_preferences_fingerprint",
        "config_loaded",
        "curl_payload",
    }) do
        if obj.store:readSetting(key, nil) ~= nil then
            if type(obj.store.delSetting) == "function" then
                obj.store:delSetting(key)
            else
                obj.store:saveSetting(key, nil)
            end
            legacy_changed = true
        end
    end
    local stored_auth_version = tonumber(obj.store:readSetting("auth_schema_version", 0)) or 0
    if stored_auth_version < Settings.AUTH_SCHEMA_VERSION then
        -- Authentication before schema v1 may have come from legacy manual
        -- flows and has no reliable QR account provenance.
        -- Invalidate only credentials; books, downloads and user preferences
        -- remain intact and the UI will guide the user through a fresh QR login.
        clear_auth_store(obj.store)
        obj.store:saveSetting("auth_schema_version", Settings.AUTH_SCHEMA_VERSION)
        legacy_changed = true
    end
    if legacy_changed then
        obj.store:flush()
    end
    -- H-8 fix: in-memory cache for the books table so get("books") does not
    -- do an O(N) disk read/merge on every call.
    obj._books_cache = nil
    obj._books_cache_dirty = true
    return setmetatable(obj, self)
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    if key ~= "books" then
        local value = self.store:readSetting(key, deepcopy(default))
        -- Type guard for known table keys: corrupted config (power loss during
        -- write) can leave a scalar instead of a table, which would crash the
        -- plugin on init. Fall back to defaults (P2-A fix).
        if defaults[key] ~= nil and type(defaults[key]) == "table" and type(value) ~= "table" then
            return deepcopy(defaults[key])
        end
        return value
    end
    -- Return cached books table if available (H-8 fix: avoid O(N) disk reads
    -- on every get("books") call).
    if self._books_cache and not self._books_cache_dirty then
        return self._books_cache
    end
    local indexes = self.store:readSetting("books", {})
    local books = {}
    -- Guard against a corrupted books table: pairs() raises on non-table
    -- values, and this path runs during document close via detect_book.
    if type(indexes) == "table" then
        for book_id, index in pairs(indexes) do
            if type(index) == "table" then
                books[book_id] = BookStore.load(self, book_id, index)
            end
        end
    end
    self._books_cache = books
    self._books_cache_dirty = false
    return books
end

function Settings:set(key, value)
    if key == "books" and type(value) == "table" then
        local indexes = {}
        for book_id, book in pairs(value) do
            local ok, index_or_err = BookStore.save(self, book_id, book)
            if not ok then
                error("Could not save book data: " .. tostring(index_or_err))
            end
            indexes[book_id] = index_or_err
        end
        value = indexes
        -- Invalidate cache (H-8 fix): next get("books") rebuilds from disk.
        self._books_cache = nil
        self._books_cache_dirty = true
    end
    self.store:saveSetting(key, value)
end

function Settings:has_legacy_book_records()
    local books = self.store:readSetting("books", {})
    return not BookStore.is_minimal_index(books)
end

function Settings:flush()
    self.store:flush()
end

function Settings:update_auth(credentials, options)
    credentials = credentials or {}
    options = options or {}
    local changed = false

    if type(credentials.cookies) == "table" then
        local cookies = credentials.cookies
        if options.replace_cookies ~= true then
            cookies = Cookie.merge(self:get("cookies", {}), cookies)
        else
            cookies = deepcopy(cookies)
        end
        self:set("cookies", cookies)
        changed = true
    end

    for _, key in ipairs({ "api_key", "wr_ticket", "wr_wrpa" }) do
        local value = credentials[key]
        if type(value) == "string" then
            self:set(key, value)
            changed = true
        end
    end
    if type(credentials.account) == "table" then
        self:set("account", deepcopy(credentials.account))
        changed = true
    end

    if changed and options.flush ~= false then
        self:flush()
    end
    return changed
end

function Settings:merge_set_cookie(set_cookie, options)
    if not set_cookie or set_cookie == "" then
        return false
    end
    local cookies = Cookie.merge_set_cookie(self:get("cookies", {}), set_cookie)
    return self:update_auth({ cookies = cookies }, {
        replace_cookies = true,
        flush = not options or options.flush ~= false,
    })
end

function Settings:get_all()
    local all = {}
    for key in pairs(defaults) do
        all[key] = self:get(key)
    end
    return all
end

function Settings:get_download_dir()
    return self.cache_dir
end

-- Pass nil or "" to reset to the default download directory.
function Settings:set_download_dir(path)
    if type(path) ~= "string" or path == "" then
        self:set("download_dir", "")
        self.cache_dir = self.default_cache_dir
    else
        self:set("download_dir", path)
        self.cache_dir = path
    end
    self:flush()
    ensure_dir(self.cache_dir)
    return self.cache_dir
end

function Settings:reset_account()
    clear_auth_store(self.store)
    self:flush()
end

function Settings:is_cookie_configured()
    return Cookie.has_login_cookie(self:get("cookies", {})) == true
end

function Settings:is_api_configured()
    return self:get("api_key", "") ~= ""
end

-- Path to the manual login template file in the KOReader settings directory.
-- Users edit this file via USB; the plugin imports and deletes it on next launch.
function Settings:get_manual_login_path()
    return DataStorage:getSettingsDir() .. "/weread_manual_login.lua"
end

-- Check for a filled-in manual login template and import its credentials.
-- Returns true on success, or (false, reason) otherwise.
--   "not_found"      – no template file present
--   "invalid_format" – Lua syntax error or non-table result
--   "not_filled"     – required fields missing or still placeholders
function Settings:import_manual_login()
    local path = self:get_manual_login_path()
    if not lfs.attributes(path, "mode") then
        return false, "not_found"
    end

    local ok_load, chunk = pcall(loadfile, path)
    if not ok_load or type(chunk) ~= "function" then
        return false, "invalid_format"
    end
    -- Sandbox: restrict the environment so the loaded file cannot access
    -- os, io, require, ffi, etc. (M-S1 fix).
    local sandbox_env = {
        table = table,
        string = string,
        tonumber = tonumber,
        tostring = tostring,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        next = next,
        select = select,
    }
    -- LuaJIT/Lua 5.1: use setfenv; Lua 5.2+: use load with env (but loadfile
    -- already loaded, so setfenv is the compatible path).
    if setfenv then
        setfenv(chunk, sandbox_env)
    end
    local ok_run, data = pcall(chunk)
    if not ok_run or type(data) ~= "table" then
        return false, "invalid_format"
    end

    local api_key = type(data.api_key) == "string" and data.api_key or ""
    local cookies = type(data.cookies) == "table" and data.cookies or {}
    local wr_skey = type(cookies.wr_skey) == "string" and cookies.wr_skey or ""
    local wr_vid  = type(cookies.wr_vid)  == "string" and cookies.wr_vid  or ""

    -- Reject empty values and unfilled placeholders.
    if api_key == "" or api_key:find("YOUR_")
        or wr_skey == "" or wr_skey:find("YOUR_")
        or wr_vid  == "" or wr_vid:find("YOUR_") then
        return false, "not_filled"
    end

    local account = type(data.account) == "table" and data.account or {}
    account.login_method = "manual"
    account.login_time   = os.time()
    account.user_vid     = wr_vid
    if not account.name or account.name == "" or account.name:find("YOUR_") then
        account.name = ""
    end

    self:update_auth({
        cookies    = cookies,
        api_key    = api_key,
        wr_ticket  = "",
        wr_wrpa    = "",
        account    = account,
    }, { replace_cookies = true })

    -- Clean up the template so it is not imported again.
    os.remove(path)
    return true
end

-- Write a commented template file to the settings directory so the user can
-- fill in credentials via USB without touching weread.lua directly.
function Settings:generate_manual_login_template()
    local path = self:get_manual_login_path()
    local lines = {
        "-- weread_manual_login.lua",
        "-- 微信读书手动登录配置文件 / WeRead manual login template",
        "--",
        "-- 使用方法 / Usage:",
        "-- 1. 填写以下字段（替换 YOUR_xxx 占位符）",
        "--    Fill in the fields below (replace YOUR_xxx placeholders)",
        "-- 2. 保存文件 / Save the file",
        "-- 3. 重启 KOReader，插件会自动导入并删除本文件",
        "--    Restart KOReader; the plugin will auto-import and delete this file",
        "--",
        "-- 获取凭证方法 / How to get credentials:",
        "-- 1. 在电脑浏览器打开 https://weread.qq.com 并微信扫码登录",
        "--    Open https://weread.qq.com in a browser and login with WeChat",
        "-- 2. 按 F12 打开开发者工具 → Application → Cookies → weread.qq.com",
        "--    Press F12 → Application → Cookies → weread.qq.com",
        "-- 3. 复制 wr_skey、wr_vid、wr_rt 的值",
        "--    Copy wr_skey, wr_vid, wr_rt values",
        "-- 4. API Key：微信读书 App → 我 → 设置 → 微信读书 Skill → 获取 API Key",
        "--    API Key: WeRead App → Me → Settings → WeRead Skill → Get API Key",
        "",
        "return {",
        '    api_key = "wrk-YOUR_API_KEY",',
        "    cookies = {",
        '        wr_skey = "YOUR_WR_SKEY",',
        '        wr_vid  = "YOUR_WR_VID",',
        '        wr_rt   = "YOUR_WR_RT",',
        "    },",
        "    account = {",
        '        name = "你的昵称 / Your nickname",',
        "    },",
        "}",
    }
    local file = io.open(path, "w")
    if not file then
        return false, "cannot_write"
    end
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    return true
end

return Settings
