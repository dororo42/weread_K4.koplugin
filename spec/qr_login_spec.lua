-- Unit tests for the QR-login poll URL serialization (upstream PR #167 port,
-- 2026-09-19): the getLoginInfo poll must always emit "&otp=" and append the
-- urlencoded verification code only when present. The pre-port shape produced
-- a bare "&otp" (no "=") on every empty-otp poll — the normal path right
-- after the QR is displayed — which some server/CDN paths reject.
--
-- The module's KOReader-facing dependencies are stubbed; _request_json is
-- replaced on a minimal instance so the built URL can be captured without
-- any network.
package.preload["device"] = function() return {} end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/widget/qrmessage"] = function() return {} end
package.preload["ui/uimanager"] = function() return {} end
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
