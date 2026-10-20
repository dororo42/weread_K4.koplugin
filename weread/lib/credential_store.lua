-- N-3 (2026-10-20 audit): account credentials (cookies / api_key / wr_ticket
-- / wr_wrpa / account) live in a dedicated file created 0600. Before v8.0
-- they rode inside weread.lua (LuaSettings, typically 0644) — readable by
-- any host user whenever the Kindle is USB-mounted. welite's store.lua
-- demonstrated the mechanism on the same flash class; this module is the K4
-- equivalent.
--
-- Write discipline (mirrors welite store.lua:95-115):
--   * remove a stale tmp, then open it O_WRONLY|O_CREAT|O_EXCL with an
--     explicit 0600 creation mode (O_EXCL refuses a pre-planted symlink or
--     hardlink at the tmp path);
--   * write the whole payload, fsync, close;
--   * os.rename(tmp, path) — the renamed file inherits the tmp's 0600 mode,
--     so the permission never depends on the process umask, and no partial
--     file is ever visible at the real path. F-11 lesson applied: os.rename
--     signals failure by RETURNING nil, so the return value is checked.
--
-- Runtime notes:
--   * On device (LuaJIT) ffi is always present and the 0600 guarantee is
--     structural. Under plain Lua 5.1 (busted/CI) the module falls back to
--     io.open + chmod so the exact same code path stays testable; that
--     fallback is never reached on device.
--   * Format is a deliberately flat, escape-based line format instead of
--     JSON: zero runtime dependencies (identical behaviour on device and in
--     tests), no load()/eval anywhere, and the payload shape is a known flat
--     map. Each line is "<escaped-key>\t<escaped-value>".
--   * load() re-validates every field (wr_* cookie names, no ';'/CR/LF in
--     values, bounded sizes) the way Cookie.merge_set_cookie does; a
--     tampered, truncated or implausible file degrades to "no credentials"
--     (the UI guides a re-login) instead of crashing the plugin.

local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi then
    pcall(require, "ffi/posix_h")
end
local ok_logger, logger = pcall(require, "weread.lib.logger")

local CredentialStore = {}
CredentialStore.__index = CredentialStore

-- 0o600, the creation mode for the tmp file (survives the rename).
CredentialStore.CREATE_MODE = 384

-- Defensive ceiling: the credential payload is a few hundred bytes in
-- practice; anything near 1 MiB is corruption or tampering.
local FILE_LIMIT = 1024 * 1024
-- Per-value cap, matching welite's store.lua validation.
local VALUE_LIMIT = 8192

-- Linux values; posix_h supplies the real ones when ffi is present.
local O_WRONLY, O_CREAT, O_EXCL = 1, 64, 128
if ok_ffi and ffi.C then
    O_WRONLY = tonumber(ffi.C.O_WRONLY) or O_WRONLY
    O_CREAT = tonumber(ffi.C.O_CREAT) or O_CREAT
    O_EXCL = tonumber(ffi.C.O_EXCL) or O_EXCL
end
-- The three flags are distinct bits, so the sum equals bit.bor here.
local OPEN_FLAGS = O_WRONLY + O_CREAT + O_EXCL

local FILE_HEADER = "weread-credentials-v1"

local function log_warn(...)
    if ok_logger and logger and type(logger.warn) == "function" then
        logger.warn(...)
    end
end

-- Escape every control character and '%' as %XX; unescape reverses it.
local function escape(text)
    return (tostring(text):gsub("[%c%%]", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

local function unescape(text)
    return (text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

-- Validate a decoded credential payload; returns the sanitized table or nil
-- when the shape is implausible. Mirrors the cookie discipline of
-- Cookie.merge_set_cookie: wr_* key names, no ';'/CR/LF in values, bounded
-- sizes (welite store.lua:29-41).
local function sanitize(data)
    if type(data) ~= "table" then
        return nil
    end
    local out = {}
    for _, key in ipairs({ "api_key", "wr_ticket", "wr_wrpa" }) do
        local value = data[key]
        if value == nil or value == "" then
            out[key] = ""
        elseif type(value) == "string" and #value <= VALUE_LIMIT
            and not value:find("[\r\n]") then
            out[key] = value
        else
            return nil
        end
    end
    local cookies = data.cookies
    if cookies == nil then
        cookies = {}
    end
    if type(cookies) ~= "table" then
        return nil
    end
    local clean_cookies = {}
    for name, value in pairs(cookies) do
        if type(name) ~= "string" or not name:match("^wr_[%w_]+$")
            or type(value) ~= "string" or #value > VALUE_LIMIT
            or value:find("[;\r\n]") then
            return nil
        end
        clean_cookies[name] = value
    end
    out.cookies = clean_cookies
    local account = data.account
    if account == nil then
        account = {}
    end
    if type(account) ~= "table" then
        return nil
    end
    out.account = {}
    for field, value in pairs(account) do
        if type(field) == "string" and #field <= 128
            and (type(value) == "string" and #value <= VALUE_LIMIT
                or type(value) == "number") then
            out.account[field] = value
        end
    end
    return out
end
CredentialStore.sanitize = sanitize

function CredentialStore.new(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return setmetatable({ path = path }, CredentialStore)
end

function CredentialStore:exists()
    local fh = io.open(self.path, "rb")
    if fh then
        fh:close()
        return true
    end
    return false
end

-- Returns a sanitized credentials table; {} when the file is missing,
-- unreadable, or fails validation (the caller then treats the account as
-- logged out — never a crash).
function CredentialStore:load()
    local fh = io.open(self.path, "rb")
    if not fh then
        return {}
    end
    local raw = fh:read(FILE_LIMIT + 1)
    fh:close()
    if not raw or #raw > FILE_LIMIT then
        log_warn("credential file unreadable or oversized, ignoring:",
            "path=", self.path, "bytes=", tostring(raw and #raw or -1))
        return {}
    end
    local data = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        if line ~= "" and line ~= FILE_HEADER then
            local key, value = line:match("^([^\t]*)\t(.*)$")
            if not key then
                log_warn("credential file malformed, ignoring:", "path=", self.path)
                return {}
            end
            key = unescape(key)
            value = unescape(value)
            local prefix, rest = key:match("^(%w+):(.*)$")
            if prefix == "cookie" then
                data.cookies = data.cookies or {}
                data.cookies[rest] = value
            elseif prefix == "account" then
                data.account = data.account or {}
                data.account[rest] = tonumber(value) or value
            else
                data[key] = value
            end
        end
    end
    local clean = sanitize(data)
    if not clean then
        log_warn("credential file failed validation, ignoring:", "path=", self.path)
        return {}
    end
    return clean
end

-- Atomic 0600 write. Returns true on success; (nil, err) on failure — the
-- previous file is left untouched on every failure path.
function CredentialStore:save(data)
    data = data or {}
    local lines = { FILE_HEADER }
    for _, key in ipairs({ "api_key", "wr_ticket", "wr_wrpa" }) do
        lines[#lines + 1] = escape(key) .. "\t" .. escape(data[key] or "")
    end
    local cookie_names = {}
    for name in pairs(data.cookies or {}) do
        cookie_names[#cookie_names + 1] = name
    end
    table.sort(cookie_names)
    for _, name in ipairs(cookie_names) do
        lines[#lines + 1] = escape("cookie:" .. name) .. "\t"
            .. escape(data.cookies[name])
    end
    local account_fields = {}
    for field in pairs(data.account or {}) do
        account_fields[#account_fields + 1] = field
    end
    table.sort(account_fields)
    for _, field in ipairs(account_fields) do
        lines[#lines + 1] = escape("account:" .. field) .. "\t"
            .. escape(tostring(data.account[field]))
    end
    local encoded = table.concat(lines, "\n") .. "\n"
    if #encoded > FILE_LIMIT then
        return nil, "payload exceeds the credential file limit"
    end

    local tmp = self.path .. ".tmp"
    os.remove(tmp)
    if ok_ffi and ffi.C then
        -- Device path (LuaJIT): open(2) with an explicit 0600 mode.
        local fd = ffi.C.open(tmp, OPEN_FLAGS,
            ffi.new("unsigned int", CredentialStore.CREATE_MODE))
        if not fd or fd < 0 then
            return nil, "open failed"
        end
        local offset = 0
        while offset < #encoded do
            local count = tonumber(ffi.C.write(
                fd, encoded:sub(offset + 1), #encoded - offset))
            if not count or count <= 0 then
                break
            end
            offset = offset + count
        end
        local flushed = ffi.C.fsync(fd) == 0
        ffi.C.close(fd)
        if offset ~= #encoded or not flushed then
            os.remove(tmp)
            return nil, "write failed"
        end
    else
        -- Non-LuaJIT fallback (busted/CI only — device always has ffi):
        -- io.open plus an explicit chmod. The path is plugin-constructed
        -- (settings dir + fixed filename) and %q-quoted, so there is no
        -- injection surface; this branch never executes on device.
        local fh = io.open(tmp, "wb")
        if not fh then
            return nil, "open failed"
        end
        local write_ok = fh:write(encoded)
        local close_ok = fh:close()
        if not write_ok or not close_ok then
            os.remove(tmp)
            return nil, "write failed"
        end
        os.execute(string.format("chmod 600 %q", tmp))
    end
    -- F-11 lesson: os.rename signals failure by RETURNING nil — check it.
    local renamed = os.rename(tmp, self.path)
    if not renamed then
        os.remove(tmp)
        return nil, "rename failed"
    end
    return true
end

return CredentialStore
