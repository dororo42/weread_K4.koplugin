-- Unit tests for the login menu item's SESSION-state display and the
-- hold-to-clear entry (2026-11-12): the item text must reflect the latched
-- session-expired state (runtime flag or persisted footer hint), not just
-- the credential presence, and the item's hold gesture must reach
-- confirmClearAccount (which previously had no UI entry at all).
--
-- All KOReader-facing dependencies are stubbed via package.preload; the
-- plugin instance is a plain table with a Menu metatable so only the
-- getMainMenuItems code path runs.

local __PRE = { "ffi/util", "weread.lib.i18n", "weread.lib.protocol",
    "weread.lib.logger", "weread.lib.plugin_util", "weread.ui.footer_indicator", "weread/ui/login_hint",
    "ui/bidi", "ui/widget/confirmbox", "ui/widget/infomessage", "ui/widget/menu",
    "weread.lib.global_state",
    "ui/uimanager", "dispatcher", "weread.ui.login_hint" }
local __OLD = {}
for _, name in ipairs(__PRE) do __OLD[name] = package.loaded[name] end

local hint_active = false
local clear_calls = 0
local qr_calls = 0
local status_calls = 0
local info_texts = {}
local transport_stub
transport_stub = {
    backend = "luasec",
    backend_explicit = false,
    last_reason = "luasec",
    resolve = function()
        -- mirror the production fallback: explicit k4tls without the
        -- library (this host has none) -> (nil, k4tls-unavailable-fallback)
        if transport_stub.backend == "k4tls" then
            return nil, "k4tls-unavailable-fallback"
        end
        return nil, "luasec"
    end,
}
local function preload_stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = factory()
end
preload_stub("ffi/util", function()
    return { template = function(t, ...)
        local n = select("#", ...)
        return n > 0 and (t:gsub("%%1", tostring((...)))) or t
    end }
end)
preload_stub("weread.lib.i18n", function()
    return { tr = function(text) return text end }
end)
preload_stub("weread.lib.protocol", function() return { is_mp_book = function() return false end } end)
preload_stub("weread.lib.logger", function()
    return { info = function() end, warn = function() end, err = function() end }
end)
preload_stub("weread.lib.plugin_util", function()
    return {
        tr = function(text) return text end,
        T = function(t, ...)
            local n = select("#", ...)
            for i = 1, n do
                t = t:gsub("%%" .. i, tostring((select(i, ...))))
            end
            return t
        end,
        safeCallback = nil,
    }
end)
preload_stub("weread.ui.footer_indicator", function()
    return {
        read_enabled = function() return false end,
        resolve_footer = function() return nil end,
        flush_store = function() end,
        install = function() return true end,
    }
end)
preload_stub("ui/bidi", function() return { dirpath = function(_s, p) return p end } end)
preload_stub("ui/widget/confirmbox", function()
    return { new = function(_class, opts) clear_calls = clear_calls + 1; return opts end }
end)
preload_stub("ui/widget/infomessage", function() return { new = function() return {} end } end)
preload_stub("ui/uimanager", function() return { show = function() end, close = function() end } end)
preload_stub("dispatcher", function() return { registerAction = function() end } end)
preload_stub("ui/widget/menu", function()
    return { new = function() return {} end }
end)
preload_stub("weread.lib.global_state", function()
    return {
        get = function() return nil end,
        set = function() end,
        clear = function() end,
    }
end)
preload_stub("weread.lib.transport", function() return transport_stub end)
preload_stub("weread/ui/login_hint", function()
    return {
        is_active = function() return hint_active end,
        show = function() end,
        hide = function() end,
    }
end)

package.loaded["weread.ui.menu"] = nil
package.loaded["weread.ui.common"] = nil
package.loaded["weread.lib.protocol"] = nil
local Menu = require("weread.ui.menu")
local Common = require("weread.ui.common")

local function build_instance(opts)
    opts = opts or {}
    clear_calls = 0
    qr_calls = 0
    status_calls = 0
    info_texts = {}
    hint_active = opts.hint_active or false
    local account = opts.account or {
        login_method = "qr", login_time = 1794000000, name = "Ray",
    }
    local instance = {
        settings = {
            get = function(_s, key)
                if key == "account" then return account end
                if key == "shelf" then return {} end
                return nil
            end,
            set = function(_s, key, value)
                opts.persisted = opts.persisted or {}
                opts.persisted[key] = value
            end,
            flush = function() end,
            is_cookie_configured = function() return true end,
            is_api_configured = function() return true end,
            cache_dir = "/tmp",
        },
        showTransientInfo = function(_s, text, secs)
            opts.transients = opts.transients or {}
            opts.transients[#opts.transients + 1] = { text = text, secs = secs }
        end,
        showInfo = function(_s, text)
            info_texts[#info_texts + 1] = text
        end,
        read_report = { session_expired = opts.session_expired or false },
        version = "test",
        ui = {},
        qr_login = { start = function() qr_calls = qr_calls + 1 end },
        safeCallback = function(_s, _label, fn) return fn end,
        confirmClearAccount = function(_s) clear_calls = clear_calls + 1 end,
        getSettingsMenuItems = function() return {} end,
    }
    return setmetatable(instance, {
        __index = function(_t, key) return Menu[key] or Common[key] end,
    })
end

local function find_login_item(items)
    for _, item in ipairs(items) do
        if type(item.text_func) == "function" then return item end
    end
    return nil
end

describe("login menu item session display (2026-11-12)", function()
    teardown(function()
        for name in pairs(package.loaded) do
            if tostring(name):find("^weread%.") or tostring(name):find("^ui/") then
                package.loaded[name] = nil
            end
        end
        package.loaded["weread.lib.transport"] = nil
        package.preload["weread.lib.transport"] = nil  -- don't leak our stub into later specs
        for _, name in ipairs(__PRE) do
            if __OLD[name] ~= nil then package.loaded[name] = __OLD[name] end
        end
    end)

    it("shows Logged in when the session is healthy", function()
        local items = build_instance():getMainMenuItems()
        local item = find_login_item(items)
        assert.is_not_nil(item)
        assert.equals("Logged in · Ray", item.text_func())
    end)

    it("shows Session expired when the runtime latch is set", function()
        local items = build_instance({ session_expired = true }):getMainMenuItems()
        assert.equals("Session expired · Ray", find_login_item(items).text_func())
    end)

    it("shows Session expired from the persisted footer hint alone (restart case)", function()
        local items = build_instance({ hint_active = true }):getMainMenuItems()
        assert.equals("Session expired · Ray", find_login_item(items).text_func())
    end)

    it("shows QR code login without account metadata", function()
        local items = build_instance({ account = {} }):getMainMenuItems()
        assert.equals("QR code login", find_login_item(items).text_func())
    end)
end)

describe("login menu item hold-to-clear (2026-11-12)", function()
    it("routes the hold gesture to confirmClearAccount", function()
        local items = build_instance():getMainMenuItems()
        local item = find_login_item(items)
        assert.is_function(item.hold_callback)
        item.hold_callback()
        assert.equals(1, clear_calls)
    end)
end)

describe("session item submenu (2026-11-12 K4 key-nav fix)", function()
    -- Device evidence: TouchMenu's hold path is touch-gesture-only
    -- (TouchMenuItem ges_events.HoldSelect = ges "hold"; the container
    -- key_events bind Back/Close/PgFwd/PgBack/arrows/Press — no hold), so
    -- on the non-touch K4 a held key repeats Press and opened the tap
    -- dialog instead of the clear confirmation. The actions must be
    -- reachable through a plain submenu.
    local function find_session_item(items)
        for _, item in ipairs(items) do
            if type(item.text_func) == "function" then return item end
        end
        return nil
    end

    it("exposes a key-navigable submenu: status, QR login, clear", function()
        local item = find_session_item(build_instance():getMainMenuItems())
        assert.is_table(item.sub_item_table)
        assert.equals(3, #item.sub_item_table)
        assert.equals("Account status", item.sub_item_table[1].text)
        assert.equals("QR code login", item.sub_item_table[2].text)
        assert.equals("Clear account", item.sub_item_table[3].text)
    end)

    it("routes the status entry to showAccountStatus", function()
        local instance = build_instance()
        instance.showAccountStatus = function() status_calls = status_calls + 1 end
        find_session_item(instance:getMainMenuItems()).sub_item_table[1].callback()
        assert.equals(1, status_calls)
    end)

    it("routes the QR entry to qr_login:start", function()
        local instance = build_instance()
        find_session_item(instance:getMainMenuItems()).sub_item_table[2].callback()
        assert.equals(1, qr_calls)
    end)

    it("routes the clear entry to confirmClearAccount", function()
        local instance = build_instance()
        find_session_item(instance:getMainMenuItems()).sub_item_table[3].callback()
        assert.equals(1, clear_calls)
    end)
end)

describe("account status dialog session line (2026-11-12)", function()
    it("reports the live session when healthy", function()
        local instance = build_instance()
        instance:showAccountStatus()
        assert.truthy(info_texts[1]:find("Session: active", 1, true))
        assert.falsy(info_texts[1]:find("expired", 1, true))
    end)

    it("reports the latched expired state and re-login requirement", function()
        local instance = build_instance({ session_expired = true })
        instance:showAccountStatus()
        assert.truthy(info_texts[1]:find("Session: expired", 1, true))
        assert.truthy(info_texts[1]:find("re-login required", 1, true))
    end)

    it("reports the expired state from the persisted footer hint alone", function()
        local instance = build_instance({ hint_active = true })
        instance:showAccountStatus()
        assert.truthy(info_texts[1]:find("Session: expired", 1, true))
    end)

    it("isSessionExpired mirrors the menu text decision", function()
        assert.is_false(build_instance():isSessionExpired())
        assert.is_true(build_instance({ session_expired = true }):isSessionExpired())
        assert.is_true(build_instance({ hint_active = true }):isSessionExpired())
    end)
end)

describe("settings TLS backend toggle (2026-11-12)", function()
    local function find_tls_item(items)
        for _, item in ipairs(items) do
            if item.text == "Rust TLS backend (k4tls)" then return item end
        end
        return nil
    end

    it("exposes a checked entry that reflects an explicit k4tls selection", function()
        -- menu.lua resolves weread.lib.transport at CALLBACK time; make sure
        -- the require hits OUR stub even if an earlier spec cached the real
        -- module in package.loaded
        package.loaded["weread.lib.transport"] = transport_stub
        local instance = build_instance()
        instance.getSettingsMenuItems = Menu.getSettingsMenuItems
        local items = instance:getSettingsMenuItems()
        local item = find_tls_item(items)
        assert.is_not_nil(item)
        assert.is_false(item.checked_func())
        transport_stub.backend = "k4tls"
        transport_stub.backend_explicit = true
        assert.is_true(item.checked_func())
        transport_stub.backend = "luasec"
        transport_stub.backend_explicit = false
    end)

    it("toggling on forces k4tls explicitly, persists it and warns when the library is missing", function()
        local transients
        local instance = build_instance()
        -- capture this instance's persist/transient channels (build_instance
        -- stores them under the opts table it closed over)
        local seen = {}
        instance.settings.set = function(_s, key, value) seen[key] = value end
        instance.showTransientInfo = function(_s, text, _secs)
            transients = transients or {}
            transients[#transients + 1] = text
        end
        instance.getSettingsMenuItems = Menu.getSettingsMenuItems
        local items = instance:getSettingsMenuItems()
        local item = find_tls_item(items)
        item.callback()
        local transport = require("weread.lib.transport")
        assert.equals("k4tls", transport.backend)
        assert.is_true(transport.backend_explicit)
        assert.equals("k4tls", seen.tls_backend)
        assert.truthy(transients and #transients > 0)  -- .so missing on host: fallback warned
        transport.backend, transport.backend_explicit = "luasec", false
    end)
end)
