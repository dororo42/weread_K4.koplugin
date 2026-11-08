-- Unit tests for the QR-login poll URL serialization (upstream PR #167 port,
-- 2026-09-19) and for the K4 physical-key exits on the QR modal (2026-11-08).
--
-- The module's KOReader-facing dependencies are stubbed; _request_json is
-- replaced on a minimal instance so the built URL can be captured without
-- any network. The QRMessage stub mimics the device widget's init(): it is an
-- InputContainer with a catch-all AnyKeyPressed binding and a dismiss_callback
-- fired from onCloseWidget.

local qr_widgets = {}
local ui_calls = { shown = {}, closed = {}, broadcasts = {}, scheduled = {}, transients = {} }

local function reset_ui_calls()
    qr_widgets = {}
    ui_calls = { shown = {}, closed = {}, broadcasts = {}, scheduled = {}, transients = {} }
end

package.preload["device"] = function()
    return {
        hasKeys = function() return true end,
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
        input = { group = { Back = { "Back" } } },
    }
end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/widget/qrmessage"] = function()
    return {
        new = function(_, opts)
            local widget = {
                opts = opts,
                -- KOReader's QRMessage:init() registers this catch-all.
                key_events = { AnyKeyPressed = { { "Any" } } },
            }
            function widget:onCloseWidget()
                if self.dismiss_callback then
                    self.dismiss_callback()
                    self.dismiss_callback = nil
                end
            end
            qr_widgets[#qr_widgets + 1] = widget
            return widget
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget)
            ui_calls.shown[#ui_calls.shown + 1] = widget
        end,
        close = function(_, widget)
            ui_calls.closed[#ui_calls.closed + 1] = widget
            if widget.onCloseWidget then widget:onCloseWidget() end
        end,
        broadcastEvent = function(_, event)
            ui_calls.broadcasts[#ui_calls.broadcasts + 1] = event
        end,
        scheduleIn = function(_, _seconds, fn)
            ui_calls.scheduled[#ui_calls.scheduled + 1] = fn
        end,
        unschedule = function() end,
        setDirty = function() end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/tmp/weread-qr-test" end,
        getFullDataDir = function() return "/tmp/weread-qr-test/data" end,
    }
end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end
-- Only urlencode is exercised by the URL construction; stubbing the protocol
-- module keeps the bit/crypto dependency chain out of the test runtime.
package.preload["weread.lib.protocol"] = function()
    return {
        urlencode = function(value)
            return (tostring(value):gsub("[^%w%-_%.~]", function(ch)
                return string.format("%%%02X", ch:byte())
            end))
        end,
    }
end

local QRLogin = require("weread.lib.qr_login")

local LOGIN_INFO_URL = "https://weread.qq.com/api/auth/getLoginInfo"

local function new_capturing_login()
    local captured = {}
    local obj = setmetatable({}, { __index = QRLogin })
    obj.login_cookies = {}
    obj._request_json = function(_self, url, _opts, _stage)
        captured[#captured + 1] = url
        -- non-succeeding payload: _poll_protocol returns it without raising
        return { succeed = false }, {}, nil
    end
    return obj, captured
end

local function new_modal_login()
    return setmetatable({
        generation = 1,
        started_at = os.time(),
        qr_dialog = nil,
        host = {
            refreshUI = function() end,
            showTransientInfo = function(_, text)
                ui_calls.transients[#ui_calls.transients + 1] = text
            end,
        },
    }, { __index = QRLogin })
end

describe("QRLogin poll URL serialization (upstream PR #167)", function()
    it("always emits '&otp=' when otp is nil (empty-otp poll)", function()
        local obj, captured = new_capturing_login()
        obj:_poll_protocol("UID-1", nil)
        assert.equals(LOGIN_INFO_URL .. "?uid=UID-1&otp=", captured[1])
    end)

    it("always emits '&otp=' when otp is an empty string", function()
        local obj, captured = new_capturing_login()
        obj:_poll_protocol("UID-1", "")
        assert.equals(LOGIN_INFO_URL .. "?uid=UID-1&otp=", captured[1])
    end)

    it("appends the urlencoded otp after '&otp=' when present", function()
        local obj, captured = new_capturing_login()
        obj:_poll_protocol("UID-1", "1234")
        assert.equals(LOGIN_INFO_URL .. "?uid=UID-1&otp=1234", captured[1])
    end)

    it("urlencodes non-URL-safe characters in the otp", function()
        local obj, captured = new_capturing_login()
        obj:_poll_protocol("UID-1", "12 34")
        assert.equals(LOGIN_INFO_URL .. "?uid=UID-1&otp=12%2034", captured[1])
    end)

    it("still urlencodes the uid", function()
        local obj, captured = new_capturing_login()
        obj:_poll_protocol("ab cd", nil)
        assert.equals(LOGIN_INFO_URL .. "?uid=ab%20cd&otp=", captured[1])
    end)

    it("raises without a uid", function()
        local obj = new_capturing_login()
        assert.has_error(function() obj:_poll_protocol("", nil) end)
    end)
end)

describe("QRLogin QR modal physical-key exits (K4, 2026-11-08)", function()
    before_each(reset_ui_calls)

    it("replaces the catch-all key binding with explicit Back / Menu exits", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        local dialog = qr_widgets[1]
        assert.is_not_nil(dialog)
        assert.is_nil(dialog.key_events.AnyKeyPressed)
        assert.same({ { "Back" } }, dialog.key_events.Close)
        assert.same({ { "Menu" } }, dialog.key_events.ExitApp)
        assert.equals("function", type(dialog.onClose))
        assert.equals("function", type(dialog.onExitApp))
    end)

    it("tells the user which keys cancel and exit", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        local hint = table.concat(ui_calls.transients, " ")
        assert.is_true(hint:find("Back", 1, true) ~= nil)
        assert.is_true(hint:find("Menu", 1, true) ~= nil)
    end)

    it("Back cancels the session and makes queued polls no-ops", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        local dialog = qr_widgets[1]
        local polled = false
        obj._poll = function() polled = true end

        dialog:onClose()

        assert.equals(2, obj.generation)
        assert.is_nil(obj.qr_dialog)
        assert.equals(dialog, ui_calls.closed[1])
        for _, fn in ipairs(ui_calls.scheduled) do fn() end
        assert.is_false(polled)
    end)

    it("Menu broadcasts the native Exit event after cancelling", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        local dialog = qr_widgets[1]

        dialog:onExitApp()

        assert.equals(2, obj.generation)
        assert.is_nil(obj.qr_dialog)
        assert.equals("Exit", ui_calls.broadcasts[1].name)
    end)

    it("a programmatic close never double-cancels via dismiss_callback", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        local dialog = qr_widgets[1]

        obj:cancel()
        -- onCloseWidget fires the upstream dismiss_callback; it must not bump
        -- generation a second time.
        dialog:onCloseWidget()

        assert.equals(2, obj.generation)
    end)
end)
