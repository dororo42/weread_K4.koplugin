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
local function preload_stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = factory()
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
        set_timeout = function() end,
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
