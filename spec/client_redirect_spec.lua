-- Unit tests for Client:request_follow redirect-credential handling
-- (2026-09-29 audit: coverage gap; the v2.5 behaviour "跨域重定向清理补全
-- 自定义认证头" had no regression test).
--
-- Contract under test:
--   * a cross-origin redirect MUST strip credential headers
--     (Cookie / Authorization / x-wr-*) before the next hop;
--   * a same-origin redirect keeps them (cookies are rebuilt per hop for
--     weread hosts anyway — the header here simulates a user-supplied one);
--   * HTTP-level 303 (and 301/302 on non-GET) downgrades to GET and drops
--     the body.
--
-- NOTE: busted runs all specs in ONE Lua state; stubs follow the
-- prefetch_guard_spec.lua pattern (preload + package.loaded, restore
-- pre-existing entries at teardown).
local __SPEC_STUB_NAMES = {
    "ltn12", "socketutil", "socket", "socket.http",
    "ffi/util", "weread.lib.i18n", "weread.lib.logger",
    "weread.lib.ipv4_dns", "weread.lib.cookie", "weread.lib.protocol",
    "weread.lib.plugin_util", "weread.lib.client",
}
local __PREEXISTING = {}
for _, name in ipairs(__SPEC_STUB_NAMES) do
    __PREEXISTING[name] = { loaded = package.loaded[name], preload = package.preload[name] }
end
-- Stub instances are created ONCE and reused: client.lua binds socketutil /
-- socket.http at require time, so re-running the factories would hand later
-- describes a fresh table while the module under test keeps the stale one.
local __STUB_INSTANCES = {}
local function preload_stub(name, factory)
    if not __STUB_INSTANCES[name] then
        __STUB_INSTANCES[name] = factory()
    end
    local instance = __STUB_INSTANCES[name]
    package.preload[name] = function() return instance end
    package.loaded[name] = instance
end
-- Each describe's teardown(__CLEAR) restores the pre-spec state; a describe
-- that runs after one of those teardowns re-installs the SAME instances.
local function reinstall_stubs()
    for name, instance in pairs(__STUB_INSTANCES) do
        package.preload[name] = function() return instance end
        package.loaded[name] = instance
    end
end

preload_stub("ltn12", function()
    return {
        source = { string = function(s) return { s } end },
        sink = {},
        chain = {},
    }
end)
preload_stub("socketutil", function()
    return {
        set_timeout = function(_self, block, total)
            _G.__SPEC_TIMEOUTS = _G.__SPEC_TIMEOUTS or {}
            _G.__SPEC_TIMEOUTS[#_G.__SPEC_TIMEOUTS + 1] = { block = block, total = total }
        end,
        reset_timeout = function() end,
        table_sink = function(_t) return function() end end,
    }
end)
preload_stub("socket", function()
    return { sleep = function() end }
end)
-- The http.request stub is replaced per test; each captured req_opts is
-- recorded in this table for assertions.
local http_requests = {}
preload_stub("socket.http", function()
    return {
        request = function(opts)
            http_requests[#http_requests + 1] = opts
            return true, 200, {}, "200"
        end,
    }
end)
preload_stub("ffi/util", function()
    return { template = function(text) return text end }
end)
preload_stub("weread.lib.i18n", function()
    return { tr = function(text) return text end }
end)
preload_stub("weread.lib.logger", function()
    return {
        info = function() end, warn = function() end, err = function() end,
        scoped = function() return { info = function() end, warn = function() end, err = function() end } end,
    }
end)
preload_stub("weread.lib.ipv4_dns", function()
    return {
        apply = function() return false end,
        is_resolution_error = function() return false end,
    }
end)
preload_stub("weread.lib.protocol", function()
    return {
        USER_AGENT = "spec-ua",
        urlencode = function(v) return tostring(v) end,
        is_success_response = function(result)
            if type(result) ~= "table" then return false end
            return result.succ == true or tonumber(result.succ) == 1
        end,
    }
end)

local function __CLEAR()
    for name, saved in pairs(__PREEXISTING) do
        if saved.loaded ~= nil then
            package.loaded[name] = saved.loaded
        else
            package.loaded[name] = nil
        end
        if saved.preload ~= nil then
            package.preload[name] = saved.preload
        else
            package.preload[name] = nil
        end
    end
end

package.loaded["weread.lib.plugin_util"] = nil
package.loaded["weread.lib.cookie"] = nil
package.loaded["weread.lib.client"] = nil
local PluginUtil = require("weread.lib.plugin_util")
local Cookie = require("weread.lib.cookie")
local Client = require("weread.lib.client")

local function new_client()
    return Client:new({
        get = function(_self, key, default)
            if key == "cookies" then return { wr_skey = "secret-skey" } end
            return default
        end,
        set = function() end,
        flush = function() end,
    })
end

-- Swap the shared http.request stub for a scripted hop sequence.
local function script_responses(responses)
    http_requests = {}
    package.loaded["socket.http"].request = function(opts)
        http_requests[#http_requests + 1] = opts
        local response = responses[#http_requests]
        if not response then
            return true, 200, {}, "200"
        end
        if response.error then
            -- LuaSocket http.request failure shape: returns (nil, err)
            return nil, response.error
        end
        return true, response.code, response.headers or {}, tostring(response.code)
    end
end

local function header(opts, name)
    local headers = opts.headers or {}
    if headers[name] ~= nil then return headers[name] end
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == name:lower() then
            return value
        end
    end
    return nil
end

describe("Client:request_follow redirect credential handling", function()
    teardown(__CLEAR)

    it("strips Cookie/Authorization/x-wr headers on a cross-origin redirect", function()
        script_responses({
            { code = 302, headers = { location = "https://evil.example.com/x" } },
        })
        local client = new_client()
        client:request_follow({
            url = "https://weread.qq.com/web/a",
            method = "GET",
            headers = { ["Authorization"] = "Bearer token", ["x-wr-ticket"] = "t" },
        })
        assert.equals(2, #http_requests)
        assert.equals("Bearer token", header(http_requests[1], "Authorization"))
        assert.equals("wr_skey=secret-skey", header(http_requests[1], "Cookie"))
        assert.is_nil(header(http_requests[2], "Authorization"))
        assert.is_nil(header(http_requests[2], "Cookie"))
        assert.is_nil(header(http_requests[2], "x-wr-ticket"))
    end)

    it("keeps the headers on a same-origin redirect", function()
        script_responses({
            { code = 302, headers = { location = "https://weread.qq.com/web/b" } },
        })
        local client = new_client()
        client:request_follow({
            url = "https://weread.qq.com/web/a",
            method = "GET",
            headers = { ["Authorization"] = "Bearer token" },
        })
        assert.equals(2, #http_requests)
        assert.equals("Bearer token", header(http_requests[2], "Authorization"))
        assert.equals("wr_skey=secret-skey", header(http_requests[2], "Cookie"))
    end)

    it("downgrades 303 to GET and drops the body on the next hop", function()
        script_responses({
            { code = 303, headers = { location = "https://weread.qq.com/web/c" } },
        })
        local client = new_client()
        client:request_follow({
            url = "https://weread.qq.com/web/a",
            method = "POST",
            body = '{"x":1}',
            headers = { ["Content-Length"] = "7" },
        })
        assert.equals(2, #http_requests)
        assert.equals("GET", http_requests[2].method)
        assert.is_nil(http_requests[2].body)
        assert.is_nil(header(http_requests[2], "Content-Length"))
    end)

    it("fails after exhausting the redirect budget", function()
        script_responses({
            { code = 302, headers = { location = "https://weread.qq.com/web/h1" } },
            { code = 302, headers = { location = "https://weread.qq.com/web/h2" } },
        })
        local client = new_client()
        local ok, err = pcall(function()
            client:request_follow({
                url = "https://weread.qq.com/web/a",
                method = "GET",
            }, 1)
        end)
        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find("Too many redirects", 1, true))
    end)

    it("keeps the real cookie merge intact for Set-Cookie responses", function()
        -- Indirect check that the real Cookie module (not a stub) is wired:
        -- merge_set_cookie applies the wr_* whitelist the redirects rely on.
        local jar = Cookie.merge_set_cookie({}, "wr_skey=abc; Path=/; HttpOnly")
        assert.equals("abc", jar.wr_skey)
        local dropped = Cookie.merge_set_cookie({}, "tracker=1; Path=/")
        assert.is_nil(dropped.tracker)
        assert.is_true(PluginUtil.lexical_normalize ~= nil)
    end)
end)

-- F-21 (2026-10-05 audit): every request must carry a total deadline. The
-- old default was total_timeout = -1 (unlimited) and a number-type
-- opts.timeout only raised the block timeout — a slow-drip connection could
-- hang a synchronous UI-thread request indefinitely.
describe("Client:request timeout pairing (F-21)", function()
    teardown(__CLEAR)
    before_each(reinstall_stubs)

    local function last_timeout()
        local calls = _G.__SPEC_TIMEOUTS or {}
        return calls[#calls]
    end

    it("pairs the 8s default block timeout with a 16s total", function()
        script_responses({})
        local client = new_client()
        client:request({ url = "https://weread.qq.com/a", method = "GET" })
        assert.equals(8, last_timeout().block)
        assert.equals(16, last_timeout().total)
    end)

    it("bounds a number-type timeout (degrade ladder) with total = block*2", function()
        script_responses({})
        local client = new_client()
        client:request({ url = "https://weread.qq.com/a", method = "GET", timeout = 4 })
        assert.equals(4, last_timeout().block)
        assert.equals(8, last_timeout().total)
    end)

    it("honours an explicit {block, total} table", function()
        script_responses({})
        local client = new_client()
        client:request({ url = "https://weread.qq.com/a", method = "GET",
            timeout = { 5, 15 } })
        assert.equals(5, last_timeout().block)
        assert.equals(15, last_timeout().total)
    end)
end)

-- F-23 (2026-10-05 audit): LuaSocket http.request signals failure by
-- RETURNING (nil, err); the old retry only inspected pcall errors, so a
-- WANT_READ ("wantread") failure never retried on the download/report paths
-- even though the QR-login path treats the same state as transient.
describe("Client:request transient retry (F-23)", function()
    teardown(__CLEAR)
    before_each(reinstall_stubs)

    it("retries once when http.request returns (nil, wantread)", function()
        script_responses({ { error = "wantread" } })
        local client = new_client()
        local _, code = client:request_follow({
            url = "https://weread.qq.com/web/a", method = "GET" })
        assert.equals(2, #http_requests)
        assert.equals(200, code)
    end)

    it("retries once on a pcall-shaped transient error (closed)", function()
        script_responses({ { error = "closed" } })
        local client = new_client()
        client:request_follow({ url = "https://weread.qq.com/web/a", method = "GET" })
        assert.equals(2, #http_requests)
    end)

    it("does NOT retry offline-class errors", function()
        script_responses({ { error = "Network is unreachable" } })
        local client = new_client()
        client:request({ url = "https://weread.qq.com/a", method = "GET" })
        assert.equals(1, #http_requests)
    end)

    it("does NOT retry timeouts (already consumed the total budget)", function()
        script_responses({ { error = "timeout" } })
        local client = new_client()
        client:request({ url = "https://weread.qq.com/a", method = "GET" })
        assert.equals(1, #http_requests)
    end)
end)

-- F-14 hardening (2026-10-05 audit): refuse https→http redirect downgrades.
-- (The cookie-leak part of the original finding was refuted —
-- is_weread_url attaches credentials over https only — so this stays a
-- plaintext-integrity guard.)
describe("Client:request_follow https downgrade refusal (F-14)", function()
    teardown(__CLEAR)
    before_each(reinstall_stubs)

    it("refuses a Location that downgrades to http", function()
        script_responses({
            { code = 302, headers = { location = "http://weread.qq.com/x" } },
        })
        local client = new_client()
        local ok, err = pcall(function()
            client:request_follow({ url = "https://weread.qq.com/a", method = "GET" })
        end)
        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find("insecure redirect downgrade refused", 1, true))
        assert.equals(1, #http_requests)
    end)
end)
