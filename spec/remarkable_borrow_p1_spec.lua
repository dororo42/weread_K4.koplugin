-- Unit tests for the reMarkable-borrow P1 batch (B2 renewal classification,
-- B4 device identity, B5 captive portal classification).
--
-- B2: client.renew_cookie must classify failures into replaced / stale /
-- expired / network (official -2013 state machine borrow) and read_report
-- must map them to renewal_* error kinds, only treating "expired" as
-- re-login-required.
--
-- B4: QRLogin.get_device_identity must generate a stable uuid-style id once
-- and persist it (official deviceId/deviceName borrow, K4-scoped).
--
-- B5: an HTTP 200 with an empty uid must be classified as a captive portal
-- (official "doRequestUid got empty UID (captive portal?)" borrow), not the
-- generic invalid-UID failure.
--
-- NOTE: busted runs all specs in ONE Lua state. We register stubs in BOTH
-- preload (so reloads re-derive them) and package.loaded (so requires
-- resolve to THESE instances), and remember which entries existed BEFORE
-- this spec so teardown restores exactly the pre-existing state (entries we
-- created are cleared, not restored -- otherwise our own stubs would shadow
-- later specs' preload factories).
local __SPEC_STUB_NAMES = {
    "weread.lib.content", "weread.lib.protocol", "weread.lib.i18n",
    "ffi/util", "ltn12", "socketutil", "socket", "socket.http",
    "weread.lib.logger", "datastorage", "device",
    "ui/widget/inputdialog", "ui/widget/qrmessage", "ui/uimanager",
}
local __PREEXISTING = {}
for _, name in ipairs(__SPEC_STUB_NAMES) do
    __PREEXISTING[name] = package.loaded[name]
end
local function preload_stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = factory()
end
preload_stub("weread.lib.content", function() return {} end)
preload_stub("weread.lib.protocol", function()
    return {
        urlencode = function(v) return tostring(v) end,
        is_success_response = function(result, field)
            if type(result) ~= "table" then return false end
            local value = result[field or "succ"]
            return value == true or tonumber(value) == 1
        end,
    }
end)
preload_stub("weread.lib.i18n", function() return { tr = function(text) return text end } end)
preload_stub("ffi/util", function() return { template = function(text) return text end } end)
preload_stub("ltn12", function() return { source = {}, sink = {}, chain = {} } end)
preload_stub("socketutil", function()
    return {
        set_timeout = function() end,
        reset_timeout = function() end,
        table_sink = function() return function() end end,
    }
end)
preload_stub("socket", function() return { sleep = function() end } end)
preload_stub("socket.http", function() return { request = function() end } end)
preload_stub("weread.lib.logger", function()
    local nillog = { info = function() end, warn = function() end, err = function() end }
    nillog.scoped = function() return { info = function() end, warn = function() end, err = function() end } end
    return nillog
end)
preload_stub("datastorage", function()
    return {
        getFullDataDir = function() return "/tmp/weread_test_data" end,
        getSettingsDir = function() return "/tmp/weread_test_settings" end,
    }
end)
-- qr_login captures this exact table at require time (local DataStorage =
-- require(...)); keep the reference so tests can neutralize the fallback on
-- the SAME instance instead of swapping in a fresh unreachable table.
local __DS_STUB = package.loaded["datastorage"]
preload_stub("device", function() return {} end)
preload_stub("ui/widget/inputdialog", function() return {} end)
preload_stub("ui/widget/qrmessage", function() return {} end)
preload_stub("ui/uimanager", function()
    return { close = function() end, show = function() end, scheduleIn = function() end }
end)
-- drop cached copies of the modules under test so they reload against
-- the stubs above
package.loaded["weread.lib.client"] = nil
package.loaded["weread.lib.qr_login"] = nil
package.loaded["weread.lib.read_report"] = nil
package.loaded["weread.lib.cookie"] = nil
package.loaded["weread.lib.plugin_util"] = nil

-- modules under test must reload against our stubs (they may carry stale
-- copies from earlier specs); preload factories stay registered
package.loaded["weread.lib.client"] = nil
package.loaded["weread.lib.qr_login"] = nil
package.loaded["weread.lib.read_report"] = nil
package.loaded["weread.lib.cookie"] = nil
package.loaded["weread.lib.plugin_util"] = nil

-- Busted runs every spec in one Lua state: earlier specs may have loaded
-- REAL weread modules (e.g. read_report_spec loads settings -> book_store
-- -> plugin_util -> json chain) into package.loaded; later specs' preload
-- stubs never fire once a module is cached. At teardown we therefore clear
-- the ENTIRE weread.* family, the UI widgets, the base-environment stubs
-- (datastorage/luasettings/lfs: later specs seed their own stores keyed by
-- their own paths) and every name we touched, so subsequent specs start
-- from the same clean state they would have had in isolation.
local function __CLEAR_WEREAD()
    for name in pairs(package.loaded) do
        if tostring(name):find("^weread%.") or tostring(name):find("^ui/")
            or tostring(name):find("^luasettings")
            or tostring(name) == "datastorage"
            or tostring(name):find("^libs/libkoreader%-lfs") then
            package.loaded[name] = nil
        end
    end
    for name, mod in pairs(__PREEXISTING) do
        if mod ~= nil then
            package.loaded[name] = mod
        end
    end
end

local Client = require("weread.lib.client")
local QRLogin = require("weread.lib.qr_login")

-- --------------------------------------------------------------------
-- Client:renew_cookie classification (B2)
-- --------------------------------------------------------------------

local function new_client(overrides)
    local client = Client:new({
        get = function(_self, key, default)
            if key == "cookies" then return {} end
            return default
        end,
        set = function() end,
        flush = function() end,
        update_auth = function() end,
    })
    if overrides then overrides(client) end
    return client
end

describe("B2 client.renew_cookie classification (reMarkable borrow)", function()
    teardown(function()
        __CLEAR_WEREAD()
    end)
    it("classifies succ=1 as replaced and persists cookies", function()
        local persisted = nil
        local client = new_client(function(c)
            c.post_json = function(_self, _url, _data, _opts)
                return { succ = true, synckey = 1 }, 200, { ["set-cookie"] = "wr_skey=new; Path=/" }
            end
            c.settings.update_auth = function(_s, updates)
                persisted = updates
            end
        end)
        local result, code = client:renew_cookie()
        assert.equals(200, code)
        assert.equals("replaced", result._renewal_outcome.status)
        assert.is_true(result._renewal_outcome.http_ok)
        assert.is_not_nil(persisted)
        assert.is_not_nil(persisted.cookies)
    end)

    it("classifies HTTP 401 as expired", function()
        local client = new_client(function(c)
            c.post_json = function()
                error("HTTP 401", 0)
            end
        end)
        local ok, err = pcall(function() client:renew_cookie() end)
        assert.is_false(ok)
        assert.equals("expired", tostring(err):match("Cookie renewal rejected %((%a+)%)"))
    end)

    it("treats an HTTP-OK rejection without a new skey as expired (official EXPIRED)", function()
        -- Official split: a bare rejection (no replacement key in the
        -- response) is SESSION_EXPIRED; K4 keeps the credentials on disk but
        -- reports the session as dead.
        local client = new_client(function(c)
            c.post_json = function()
                return { succ = false, errCode = -2013, errMsg = "invalid session" }, 200, {}
            end
        end)
        local ok, err = pcall(function() client:renew_cookie() end)
        assert.is_false(ok)
        assert.equals("expired", tostring(err):match("Cookie renewal rejected %((%a+)%)"))
    end)

    it("classifies a transport failure as network", function()
        local client = new_client(function(c)
            c.post_json = function()
                error("timeout", 0)
            end
        end)
        local ok, err = pcall(function() client:renew_cookie() end)
        assert.is_false(ok)
        -- error() prepends position info; match on the tail of the message
        assert.is_not_nil(tostring(err):find("Cookie renewal network failure", 1, true))
        -- no "rejected" marker in network failures
        assert.is_nil(tostring(err):match("Cookie renewal rejected %((%a+)%)"))
    end)

    it("classifies a non-401/403 HTTP error via its message", function()
        local client = new_client(function(c)
            c.post_json = function()
                error("HTTP 500, content_type=application/json", 0)
            end
        end)
        local ok, err = pcall(function() client:renew_cookie() end)
        assert.is_false(ok)
        -- generic server error without session wording stays "stale"
        assert.equals("stale", tostring(err):match("Cookie renewal rejected %((%a+)%)"))
    end)

    it("stores the replacement skey and returns stale when -2013 carries a new key (official STALE)", function()
        local stored = nil
        local client = new_client(function(c)
            c.post_json = function()
                return { succ = false, errCode = -2013 }, 200,
                    { ["set-cookie"] = "wr_skey=BRANDNEW; Path=/; Domain=.weread.qq.com" }
            end
            c.settings.update_auth = function(_s, updates)
                stored = updates
            end
        end)
        local ok, err = pcall(function() client:renew_cookie() end)
        assert.is_false(ok)
        assert.equals("stale", tostring(err):match("Cookie renewal rejected %((%a+)%)"))
        assert.is_not_nil(stored)
        assert.is_not_nil(stored.cookies and stored.cookies.wr_skey == "BRANDNEW")
    end)

    it("treats an HTTP-OK rejection without a new skey as expired (official EXPIRED)", function()
        local client = new_client(function(c)
            c.post_json = function()
                return { succ = false, errCode = -2013 }, 200, {}
            end
        end)
        local ok, err = pcall(function() client:renew_cookie() end)
        assert.is_false(ok)
        assert.equals("expired", tostring(err):match("Cookie renewal rejected %((%a+)%)"))
    end)
end)

-- --------------------------------------------------------------------
-- ReadReport: renewal failure -> error_kind mapping (B2)
-- --------------------------------------------------------------------

package.preload["weread.lib.logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        scoped = function() return { info = function() end, warn = function() end, err = function() end } end,
    }
end
local ReadReport = require("weread.lib.read_report")

local function new_report()
    local scheduler = {
        scheduleIn = function() end,
        unschedule = function() end,
    }
    local report = ReadReport:new{
        settings = {
            get = function(_self, key, default)
                if key == "read_report" then return { enabled = true, mode = "manual", book_id = "B1", interval_seconds = 30 } end
                return default
            end,
            set = function() end,
            flush = function() end,
            is_cookie_configured = function() return true end,
        },
        client = {},
        scheduler = scheduler,
        get_document = function() return {} end,
        detect_book = function() return "B1" end,
        is_online = function() return true end,
        now = function() return 1000000 end,
    }
    return report
end

describe("B2 ReadReport renewal error kinds (reMarkable borrow)", function()
    local function outcome_with_renewal(status, message)
        -- mirror the real _run_pipeline outcome shape: the pipeline maps
        -- renewal_status -> error_kind before _apply_outcome sees it
        return {
            accepted = false,
            renew_attempted = true,
            renewal_status = status,
            error_kind = "renewal_" .. status,
            error = message or ("read report cookie renewal failed (" .. status .. "): test"),
        }
    end

    it("maps network status to renewal_network and keeps the session", function()
        local report = new_report()
        local outcome = outcome_with_renewal("network")
        report:_apply_outcome(outcome)
        assert.equals("renewal_network", report.last_error_kind)
        assert.equals("network", report.last_renewal_status)
    end)

    it("maps stale status to renewal_stale without demanding re-login", function()
        local report = new_report()
        local outcome = outcome_with_renewal("stale")
        report:_apply_outcome(outcome)
        assert.equals("renewal_stale", report.last_error_kind)
        assert.equals("stale", report.last_renewal_status)
    end)

    it("maps expired status to renewal_expired (re-login required)", function()
        local report = new_report()
        local outcome = outcome_with_renewal("expired")
        report:_apply_outcome(outcome)
        assert.equals("renewal_expired", report.last_error_kind)
        assert.equals("expired", report.last_renewal_status)
    end)

    it("records replaced on a successful renewal outcome", function()
        local report = new_report()
        report:_apply_outcome({
            accepted = true,
            reported_seconds = 30,
            renewal_status = "replaced",
        })
        assert.equals("replaced", report.last_renewal_status)
        assert.is_nil(report.last_error)
    end)

    it("status() exposes last_renewal_status", function()
        local report = new_report()
        report.last_renewal_status = "stale"
        local st = report:status()
        assert.equals("stale", st.last_renewal_status)
    end)
end)

-- --------------------------------------------------------------------
-- B4: device identity stability
-- --------------------------------------------------------------------

describe("B4 QRLogin device identity (reMarkable borrow, K4-scoped)", function()
    local function fresh_settings(tmpdir)
        return { data_dir = tmpdir }
    end

    it("generates a stable id persisted across calls", function()
        -- os.tmpname returns a FILE path; turn it into a real directory so
        -- the identity file can be written and re-read (portable: cmd
        -- builtin on Windows, mkdir binary on the Linux CI).
        local tmp = os.tmpname()
        os.remove(tmp)
        if package.config:sub(1, 1) == "\\" then
            os.execute('mkdir "' .. tmp .. '" 2>nul')
        else
            os.execute('mkdir -p "' .. tmp .. '" 2>/dev/null')
        end
        local settings = fresh_settings(tmp)
        local first = QRLogin.get_device_identity(settings)
        assert.is_not_nil(first)
        -- Debug visibility on CI: the id must be a non-empty hex-ish string.
        -- (luassert's failure message includes the value, so a failed assert
        -- below prints the actual id in the busted output.)
        assert.equals("string", type(first.id))
        assert.is_true(#first.id >= 8)
        local second = QRLogin.get_device_identity(settings)
        assert.equals(first.id, second.id)
        assert.equals("Kindle K4 - weread_K4", first.name)
        pcall(os.remove, tmp .. "/weread_device_id")
        if package.config:sub(1, 1) == "\\" then
            pcall(function() os.execute('rmdir "' .. tmp .. '" 2>nul') end)
        else
            pcall(os.remove, tmp)
        end
    end)

    it("returns nil when the resolved data dir is empty (nil-safe)", function()
        -- Pure-logic branch: an empty settings table with no DataStorage
        -- fallback resolves to the bare suffix, and get_device_identity must
        -- return nil instead of touching the filesystem root. qr_login holds
        -- the module instance captured at require time (__DS_STUB), so
        -- neutralize THAT table.
        local old_get = __DS_STUB.getFullDataDir
        __DS_STUB.getFullDataDir = nil
        local identity = QRLogin.get_device_identity({})
        __DS_STUB.getFullDataDir = old_get
        assert.is_nil(identity)
    end)
end)

-- --------------------------------------------------------------------
-- B5: captive portal classification via _begin_protocol
-- --------------------------------------------------------------------

describe("B5 captive portal classification (reMarkable borrow)", function()
    it("marks an HTTP 200 empty-uid response as captive portal", function()
        local qr = QRLogin:new({}, {
            request_follow = function(_self, opts)
                return "page", 200, {}
            end,
            request = function(_self, opts)
                -- portal hijack: 200 OK, JSON body without uid
                return "{}", 200, {}
            end,
            decode_http_json = function(_self, text)
                return {}
            end,
        }, { data_dir = os.tmpname() })
        local ok = pcall(function() return qr:_begin_protocol() end)
        assert.is_false(ok)
        assert.equals("captive_portal", qr.last_login_error_kind)
    end)
end)
