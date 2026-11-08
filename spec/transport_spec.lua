local module_name = "weread.lib.transport"

describe("weread.lib.transport deterministic selection", function()
    local saved, getenv, env, options, state, k4tls, http
    before_each(function()
        saved = {}
        for _, name in ipairs({ module_name, "weread.lib.k4tls", "socket.http" }) do
            saved[name] = { loaded = package.loaded[name], preload = package.preload[name] }
            package.loaded[name] = nil
        end
        getenv = os.getenv
        env = nil
        rawset(os, "getenv", function(name)
            if name == "WEREAD_TLS_BACKEND" then return env end
            return getenv(name)
        end)
        options = { available = true }
        state = { probes = 0, tls_calls = 0, http_calls = 0 }
        k4tls = {
            is_available = function()
                state.probes = state.probes + 1
                return options.available
            end,
            request = function(req)
                state.tls_calls = state.tls_calls + 1
                state.request = req
                if options.tls_error then return nil, options.tls_error end
                if options.tls_exception then error(options.tls_exception) end
                return 1, 201, state.tls_headers, "TLS status"
            end,
        }
        http = { request = function(req)
            state.http_calls = state.http_calls + 1
            state.request = req
            if options.http_error then return nil, options.http_error end
            return 1, 202, state.http_headers, "LuaSec status"
        end }
        state.tls_headers, state.http_headers = { TLS = "yes" }, { LuaSec = "yes" }
        package.preload["weread.lib.k4tls"] = function()
            if options.missing_tls then error("stub: missing k4tls module") end
            return k4tls
        end
        package.preload["socket.http"] = function()
            if options.missing_http then error("stub: missing socket.http module") end
            return http
        end
    end)
    after_each(function()
        rawset(os, "getenv", getenv)
        for name, previous in pairs(saved) do
            package.loaded[name], package.preload[name] = previous.loaded, previous.preload
        end
    end)

    local function check_request(transport, tls)
        local req = { url = "https://stub.invalid/", sink = function() return 1 end }
        local first, code, headers, status = transport.request(req)
        assert.equals(1, first)
        assert.equals(tls and 201 or 202, code)
        assert.equals(tls and state.tls_headers or state.http_headers, headers)
        assert.equals(tls and "TLS status" or "LuaSec status", status)
        assert.equals(req, state.request)
        assert.equals(tls and 1 or 0, state.tls_calls)
        assert.equals(tls and 0 or 1, state.http_calls)
    end
    it("defaults to LuaSec even with a loadable TLS library", function()
        local transport = require(module_name)
        assert.equals("luasec", transport.backend)
        local backend, reason = transport.resolve()
        assert.is_nil(backend)
        assert.equals("luasec", reason)
        check_request(transport, false)
        assert.equals(0, state.probes)
    end)
    for _, chosen in ipairs({ "luasec", "typo", "", false }) do
        it("fails safe without probing k4tls for backend " .. tostring(chosen), function()
            local transport = require(module_name)
            transport.backend = chosen
            local backend, reason = transport.resolve()
            assert.is_nil(backend)
            assert.equals("luasec", reason)
            check_request(transport, false)
            assert.equals(0, state.probes)
        end)
    end
    for _, chosen in ipairs({ "auto", "k4tls" }) do
        it("honors explicit " .. chosen .. " selection", function()
            local transport = require(module_name)
            transport.backend = chosen
            local backend, reason = transport.resolve()
            assert.equals(k4tls, backend)
            assert.equals("k4tls", reason)
            check_request(transport, true)
        end)
        it("falls back if " .. chosen .. " cannot load the library", function()
            options.available = false
            local transport = require(module_name)
            transport.backend = chosen
            local backend, reason = transport.resolve()
            assert.is_nil(backend)
            assert.equals("luasec-fallback", reason)
            check_request(transport, false)
        end)
        it("falls back if " .. chosen .. " cannot load the k4tls module", function()
            options.missing_tls = true
            local transport = require(module_name)
            transport.backend = chosen
            local backend, reason = transport.resolve()
            assert.is_nil(backend)
            assert.equals("luasec-fallback", reason)
            check_request(transport, false)
            assert.equals(0, state.probes)
        end)
    end
    for _, chosen in ipairs({ "auto", "k4tls", "luasec", "typo" }) do
        it("honors the environment override " .. chosen, function()
            env = chosen
            local transport = require(module_name)
            transport.backend = chosen == "luasec" and "k4tls" or "luasec"
            local tls = chosen == "auto" or chosen == "k4tls"
            check_request(transport, tls)
            assert.equals(tls and 1 or 0, state.probes)
        end)
    end
    it("ignores an empty environment override", function()
        env = ""
        local transport = require(module_name)
        transport.backend = "k4tls"
        check_request(transport, true)
    end)
    for _, backend in ipairs({ "luasec", "auto", "k4tls" }) do
        it("returns nil,error when no backend is available for " .. backend, function()
            options.available, options.missing_http = false, true
            local transport = require(module_name)
            transport.backend = backend
            local first, err, third = transport.request({ url = "https://stub.invalid/" })
            assert.is_nil(first)
            assert.equals("transport: no backend available", err)
            assert.is_nil(third)
            assert.equals(0, state.tls_calls)
            assert.equals(0, state.http_calls)
        end)
    end
    it("can use k4tls without LuaSec installed when explicitly enabled", function()
        options.missing_http = true
        local transport = require(module_name)
        transport.backend = "k4tls"
        check_request(transport, true)
    end)
    it("preserves LuaSec nil,error without changing its shape", function()
        options.http_error = "LuaSec failure"
        local transport = require(module_name)
        transport.backend = "luasec"
        local first, err, third = transport.request({})
        assert.is_nil(first)
        assert.equals("LuaSec failure", err)
        assert.is_nil(third)
        assert.equals(1, state.http_calls)
        assert.equals(0, state.tls_calls)
    end)
    it("does not retry TLS request failures through LuaSec", function()
        options.tls_error = "certificate verify failed"
        local transport = require(module_name)
        transport.backend = "k4tls"
        local first, err, third = transport.request({})
        assert.is_nil(first)
        assert.equals("certificate verify failed", err)
        assert.is_nil(third)
        assert.equals(1, state.tls_calls)
        assert.equals(0, state.http_calls)
    end)
    it("does not swallow TLS exceptions or retry through LuaSec", function()
        options.tls_exception = "TLS raised"
        local transport = require(module_name)
        transport.backend = "auto"
        local ok, err = pcall(transport.request, {})
        assert.is_false(ok)
        assert.truthy(tostring(err):find("TLS raised", 1, true))
        assert.equals(1, state.tls_calls)
        assert.equals(0, state.http_calls)
    end)
end)
