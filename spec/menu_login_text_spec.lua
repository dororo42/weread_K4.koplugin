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
    "ui/bidi", "ui/widget/confirmbox", "ui/widget/infomessage",
    "ui/uimanager", "dispatcher", "weread.ui.login_hint" }
local __OLD = {}
for _, name in ipairs(__PRE) do __OLD[name] = package.loaded[name] end

local hint_active = false
local clear_calls = 0

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
        T = function(t, ...) return (t:gsub("%%1", tostring(select(1, ...) or ""))) end,
        safeCallback = nil,
    }
end)
preload_stub("weread.ui.footer_indicator", function() return {} end)
preload_stub("ui/bidi", function() return { dirpath = function(_s, p) return p end } end)
preload_stub("ui/widget/confirmbox", function()
    return { new = function(_class, opts) clear_calls = clear_calls + 1; return opts end }
end)
preload_stub("ui/widget/infomessage", function() return { new = function() return {} end } end)
preload_stub("ui/uimanager", function() return { show = function() end, close = function() end } end)
preload_stub("dispatcher", function() return { registerAction = function() end } end)
preload_stub("weread/ui/login_hint", function()
    return {
        is_active = function() return hint_active end,
        show = function() end,
        hide = function() end,
    }
end)

package.loaded["weread.ui.menu"] = nil
package.loaded["weread.lib.protocol"] = nil
local Menu = require("weread.ui.menu")

local function build_instance(opts)
    opts = opts or {}
    clear_calls = 0
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
            is_cookie_configured = function() return true end,
            is_api_configured = function() return true end,
            cache_dir = "/tmp",
        },
        read_report = { session_expired = opts.session_expired or false },
        version = "test",
        ui = {},
        qr_login = {},
        safeCallback = function(_s, _label, fn) return fn end,
        showAccountStatus = function() end,
        confirmClearAccount = function(_s) clear_calls = clear_calls + 1 end,
        getSettingsMenuItems = function() return {} end,
    }
    return setmetatable(instance, { __index = Menu })
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
