-- Unit tests for the QR-login poll URL serialization (upstream PR #167 port,
-- 2026-09-19) and for the K4 physical-key exits on the QR modal (2026-11-08).
--
-- The module's KOReader-facing dependencies are stubbed; _request_json is
-- replaced on a minimal instance so the built URL can be captured without
-- any network. The QRMessage stub mimics the device widget's init(): it is an
-- InputContainer with a catch-all AnyKeyPressed binding and a dismiss_callback
-- fired from onCloseWidget.

local qr_widgets = {}
local function fresh_ui_calls()
    return {
        shown = {}, closed = {}, broadcasts = {}, scheduled = {},
        schedules = {}, transients = {}, hints = {}, hint_texts = {},
        show_args = {},
        hint_hides = 0, infos = {},
    }
end
local ui_calls = fresh_ui_calls()

local function reset_ui_calls()
    qr_widgets = {}
    ui_calls = fresh_ui_calls()
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
package.preload["weread/ui/login_hint"] = function()
    return {
        hide = function() ui_calls.hint_hides = (ui_calls.hint_hides or 0) + 1 end,
        show = function() end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget, refreshtype, region)
            ui_calls.shown[#ui_calls.shown + 1] = widget
            ui_calls.show_args[#ui_calls.show_args + 1] = { refreshtype = refreshtype, region = region }
        end,
        close = function(_, widget)
            ui_calls.closed[#ui_calls.closed + 1] = widget
            if widget.onCloseWidget then widget:onCloseWidget() end
        end,
        broadcastEvent = function(_, event)
            ui_calls.broadcasts[#ui_calls.broadcasts + 1] = event
        end,
        scheduleIn = function(_, seconds, fn)
            ui_calls.scheduled[#ui_calls.scheduled + 1] = fn
            ui_calls.schedules[#ui_calls.schedules + 1] = {
                seconds = seconds, fn = fn,
            }
        end,
        unschedule = function() end,
        setDirty = function() end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
-- 2026-11-10 (K4 fix): the key legend is a bottom-anchored bar now — these
-- stubs exist so the hint widget chain can be observed in the tests below.
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return t end }
end
package.preload["ui/font"] = function()
    return { getFace = function() return { name = "stub" } end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = "white-stub" }
end
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts)
            ui_calls.hint_texts[#ui_calls.hint_texts + 1] = opts.text
            return opts
        end,
    }
end
package.preload["ui/widget/container/framecontainer"] = function()
    return {
        new = function(_, opts)
            function opts.getSize()
                return { w = 280, h = 36 }
            end
            return opts
        end,
    }
end
package.preload["ui/widget/container/bottomcontainer"] = function()
    return {
        new = function(_, opts)
            -- Mirrors the real BottomContainer:contentRange math so the
            -- refresh-region assertions below exercise the same shape.
            function opts:contentRange()
                local cs = self[1]:getSize()
                return {
                    x = (self.dimen.x or 0) + math.floor((self.dimen.w - cs.w) / 2),
                    y = (self.dimen.y or 0) + self.dimen.h - cs.h,
                    w = cs.w,
                    h = cs.h,
                }
            end
            ui_calls.hints[#ui_calls.hints + 1] = opts
            return opts
        end,
    }
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
            showInfo = function(_, text)
                ui_calls.infos[#ui_calls.infos + 1] = text
            end,
        },
    }, { __index = QRLogin })
end

-- U17-2 (2026-11-10, upstream #201): the QR dialog is rendered by a 0.2s
-- deferred callback. Flush exactly that callback so the pre-existing modal
-- tests keep observing a displayed dialog/hint.
local function flush_qr_show()
    for _, entry in ipairs(ui_calls.schedules) do
        if entry.seconds == 0.2 then
            entry.fn()
            return
        end
    end
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
        flush_qr_show()
        local dialog = qr_widgets[1]
        assert.is_not_nil(dialog)
        assert.is_nil(dialog.key_events.AnyKeyPressed)
        assert.same({ { "Back" } }, dialog.key_events.Close)
        assert.same({ { "Menu" } }, dialog.key_events.ExitApp)
        assert.equals("function", type(dialog.onClose))
        assert.equals("function", type(dialog.onExitApp))
    end)

    it("anchors the key legend at the screen bottom, not a centered toast", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        flush_qr_show()
        -- The old centered InfoMessage landed here (it overlaps the QR code).
        assert.equals(0, #ui_calls.transients)
        assert.equals(1, #ui_calls.hints)
        -- Full-screen BottomContainer so the frame hugs the screen bottom,
        -- clear of the 72%-viewport QR.
        assert.equals(600, ui_calls.hints[1].dimen.w)
        assert.equals(800, ui_calls.hints[1].dimen.h)
        local legend = table.concat(ui_calls.hint_texts, " ")
        assert.is_true(legend:find("Back", 1, true) ~= nil)
        assert.is_true(legend:find("Menu", 1, true) ~= nil)
    end)

    it("shows the legend with an explicit bottom-strip refresh region", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        flush_qr_show()
        -- UIManager:show() without a refreshtype drops the refresh entirely
        -- (uimanager.lua:1123, v2026.07.1): the bar would be painted into
        -- the framebuffer but never reach the e-ink panel. Pin the explicit
        -- non-flashing refresh over just the legend strip.
        local hint_args
        for i, widget in ipairs(ui_calls.shown) do
            if widget == ui_calls.hints[1] then
                hint_args = ui_calls.show_args[i]
            end
        end
        assert.is_not_nil(hint_args)
        assert.equals("ui", hint_args.refreshtype)
        assert.is_not_nil(hint_args.region)
        assert.equals(800, hint_args.region.y + hint_args.region.h)
        assert.is_true(hint_args.region.h < 800)
    end)

    it("hides the legend through the _close_qr_dialog funnel", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        flush_qr_show()
        local dialog = qr_widgets[1]

        dialog:onClose()

        -- The hint is torn down first, then the dialog itself.
        assert.equals(ui_calls.hints[1], ui_calls.closed[1])
        assert.equals(dialog, ui_calls.closed[2])
        assert.is_nil(obj.qr_hint)
    end)

    it("Back cancels the session and makes queued polls no-ops", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        flush_qr_show()
        local dialog = qr_widgets[1]
        local polled = false
        obj._poll = function() polled = true end

        dialog:onClose()

        assert.equals(2, obj.generation)
        assert.is_nil(obj.qr_dialog)
        assert.equals(dialog, ui_calls.closed[2])
        for _, fn in ipairs(ui_calls.scheduled) do fn() end
        assert.is_false(polled)
    end)

    it("Menu broadcasts the native Exit event after cancelling", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        flush_qr_show()
        local dialog = qr_widgets[1]

        dialog:onExitApp()

        assert.equals(2, obj.generation)
        assert.is_nil(obj.qr_dialog)
        assert.equals("Exit", ui_calls.broadcasts[1].name)
    end)

    it("a programmatic close never double-cancels via dismiss_callback", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        flush_qr_show()
        local dialog = qr_widgets[1]

        obj:cancel()
        -- onCloseWidget fires the upstream dismiss_callback; it must not bump
        -- generation a second time.
        dialog:onCloseWidget()

        assert.equals(2, obj.generation)
    end)
end)

-- 2026-11-10 (device K5): a deliberate re-login stops the report with
-- reason=account_cleared, and the relogin path clears the expired-session
-- latch BEFORE any later accepted report — so the persisted footer hint
-- stayed stuck forever and reading time kept accumulating with no tick.
-- Login completion must re-arm the report and tear the hint down itself.
describe("QRLogin completion teardown (2026-11-10 footer-stuck fix)", function()
    local host, qr

    before_each(function()
        reset_ui_calls()
        local report = {
            reset_failure_streak = function(_s, reason)
                ui_calls.report_calls = ui_calls.report_calls or {}
                ui_calls.report_calls[#ui_calls.report_calls + 1] = { op = "reset", reason = reason }
            end,
            maybe_start = function(_s, reason)
                ui_calls.report_calls = ui_calls.report_calls or {}
                ui_calls.report_calls[#ui_calls.report_calls + 1] = { op = "start", reason = reason }
            end,
        }
        host = {
            ui = {},
            read_report = report,
            showBusy = function() end,
            closeBusy = function() end,
            refreshLoginMenu = function() end,
            showInfo = function() end,
            runOnlineTask = function(_h, _label, fn) fn() end,
        }
        qr = QRLogin:new(host, {}, {})
        qr._complete_protocol = function()
            return { name = "Ray", user_vid = "1", login_method = "qr",
                login_time = 0, device_id = "", device_name = "" }
        end
    end)

    it("restarts a report stopped by account_cleared and resets the streak", function()
        qr:_complete({ succeed = true }, qr.generation)
        local calls = ui_calls.report_calls or {}
        assert.equals(2, #calls)
        assert.same({ op = "reset", reason = "relogin" }, calls[1])
        assert.same({ op = "start", reason = "relogin" }, calls[2])
    end)

    it("tears down the persisted footer hint unconditionally", function()
        qr:_complete({ succeed = true }, qr.generation)
        assert.equals(1, ui_calls.hint_hides)
    end)
end)

-- Upstream v1.7.0 review (2026-11-10): U17-1 / U17-2.
describe("QRLogin transport failures keep polling (upstream #181)", function()
    before_each(reset_ui_calls)

    local function new_failing_login(err)
        local obj = setmetatable({}, { __index = QRLogin })
        obj.login_cookies = {}
        obj._request_json = function() return nil, {}, err end
        return obj
    end

    for _, err in ipairs({ "closed", "connection reset", "request failed",
        "timeout", "wantread" }) do
        it("treats '" .. err .. "' as transport_pending (no raise)", function()
            local obj = new_failing_login(err)
            local ok, result = pcall(obj._poll_protocol, obj, "UID-1", "")
            assert.is_true(ok)
            assert.is_true(result.transport_pending)
        end)
    end

    it("does not cancel the QR session when a poll hits a closed socket", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        flush_qr_show()
        obj._request_json = function() return nil, {}, "closed" end
        local before = #ui_calls.scheduled
        obj:_poll("UID-1", 1)
        assert.equals(1, obj.generation)
        assert.equals(0, #ui_calls.closed)
        assert.equals(0, #ui_calls.infos)
        assert.equals(before + 1, #ui_calls.scheduled)
    end)
end)

describe("QRLogin defers dialog rendering (upstream #201)", function()
    before_each(reset_ui_calls)

    it("renders via a 0.2s deferred callback, not immediately", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        assert.equals(0, #ui_calls.shown)
        assert.equals(0, #ui_calls.hints)
        assert.equals(0.2, ui_calls.schedules[1].seconds)
        flush_qr_show()
        assert.equals(qr_widgets[1], ui_calls.shown[1])
        assert.equals(1, #ui_calls.hints)
    end)

    it("skips the deferred render after the session was cancelled", function()
        local obj = new_modal_login()
        obj:_show_qr("UID-1", 1)
        obj:cancel()
        flush_qr_show()
        assert.equals(0, #ui_calls.shown)
        assert.equals(0, #ui_calls.hints)
    end)
end)
