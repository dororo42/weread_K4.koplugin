local module_name = "weread.lib.k4tls"
local ffi_ok, real_ffi = pcall(require, "ffi")

local function fake_ffi(options)
    local state = { loads = {}, cdefs = 0, performs = 0, frees = 0, copies = 0, strings = 0,
        attaches = 0, detaches = 0 }
    local ffi, lib = {}, {}
    function ffi.cdef(definition)
        assert.truthy(definition:find("k4tls_response_t", 1, true))
        state.cdefs = state.cdefs + 1
    end
    function ffi.load(name)
        state.loads[#state.loads + 1] = name
        if options.missing_library then error("stub: missing library") end
        return lib
    end
    function ffi.new(kind, _, value)
        if kind == "k4tls_response_t" then
            state.response = { status = 0, body_len = 0, err = { bytes = "" } }
            return state.response
        end
        if kind == "k4tls_request_t" or kind == "const char*[?]" then return {} end
        if kind == "char[?]" or kind == "unsigned char[?]" then return { bytes = value } end
        error("unexpected allocation: " .. kind)
    end
    function ffi.copy()
        state.copies = state.copies + 1
        error("ffi.copy cannot read a pointer into a Lua string; use ffi.string(ptr, len)")
    end
    function ffi.string(ptr, len)
        assert.equals(0, state.frees)
        assert.equals("table", type(ptr))
        if ptr.kind == "body" then
            assert.equals(state.response.body_len, len)
            state.strings = state.strings + 1
        end
        if options.copy_error and ptr.kind == options.copy_error then error("stub copy failure: " .. ptr.kind) end
        if len then return ptr.bytes:sub(1, len) end
        return ptr.bytes:match("^[^%z]*")
    end
    function ffi.gc(resp, finalizer)
        assert.equals(state.response, resp)
        if finalizer then
            assert.equals(0, options.rc or 0)
            assert.equals(lib.k4tls_free_response, finalizer)
            state.attaches = state.attaches + 1
        else
            state.detaches = state.detaches + 1
        end
        state.finalizer = finalizer
        return resp
    end
    function lib.k4tls_perform(req, resp)
        state.performs = state.performs + 1
        state.request = req
        resp.err = { bytes = options.detail or "", kind = "err" }
        if options.rc and options.rc ~= 0 then return options.rc end
        resp.status = options.status or 200
        if options.body then
            resp.body = { bytes = options.body, kind = "body" }
            resp.body_len = #options.body
        end
        if options.headers then resp.headers_blob = { bytes = options.headers, kind = "headers" } end
        return 0
    end
    function lib.k4tls_free_response(resp)
        assert.equals(0, options.rc or 0)
        assert.equals(state.response, resp)
        assert.equals(0, state.frees)
        state.frees = state.frees + 1
        if resp.body then resp.body.bytes = "freed" end
        if resp.headers_blob then resp.headers_blob.bytes = "freed" end
        resp.body, resp.headers_blob, resp.body_len = nil, nil, 0
    end
    function lib.k4tls_version() return { bytes = "stub k4tls" } end
    return ffi, state
end

describe("weread.lib.k4tls deterministic adapter", function()
    local saved, getenv, env, options, state, k4tls
    before_each(function()
        saved = {}
        for _, name in ipairs({ module_name, "ffi" }) do
            saved[name] = { loaded = package.loaded[name], preload = package.preload[name] }
            package.loaded[name] = nil
        end
        getenv = os.getenv
        env = nil
        rawset(os, "getenv", function(name)
            if name == "WEREAD_TLS_BACKEND" then return env end
            return getenv(name)
        end)
        options = {}
        local ffi
        ffi, state = fake_ffi(options)
        package.preload.ffi = function() return ffi end
        k4tls = require(module_name)
    end)
    after_each(function()
        rawset(os, "getenv", getenv)
        for name, previous in pairs(saved) do
            package.loaded[name], package.preload[name] = previous.loaded, previous.preload
        end
    end)

    local function request(extra)
        local opts = extra or {}
        if opts.url == nil then opts.url = "https://stub.invalid/path" end
        return k4tls.request(opts)
    end
    local function released()
        assert.equals(1, state.frees)
        assert.equals(1, state.attaches)
        assert.equals(1, state.detaches)
        assert.is_nil(state.finalizer)
    end
    local function failure(first, err, third, needle)
        assert.is_nil(first)
        assert.equals("string", type(err))
        assert.truthy(err:find(needle, 1, true))
        assert.is_nil(third)
    end

    it("defaults to LuaSec even when the library is loadable", function()
        assert.equals("luasec", k4tls.backend)
        assert.is_nil(k4tls.select())
        assert.equals(0, #state.loads)
    end)
    it("keeps unknown backend values on LuaSec without probing the library", function()
        assert.is_nil(k4tls.select("typo"))
        assert.equals(0, #state.loads)
    end)
    it("forces LuaSec without probing the library", function()
        assert.is_nil(k4tls.select("luasec"))
        assert.equals(0, #state.loads)
    end)
    for _, backend in ipairs({ "auto", "k4tls" }) do
        it("explicitly selects " .. backend .. " and caches the library", function()
            assert.equals(k4tls, k4tls.select(backend))
            assert.equals(k4tls, k4tls.select(backend))
            assert.equals(1, #state.loads)
            assert.equals(1, state.cdefs)
            assert.equals("stub k4tls", k4tls.version())
        end)
        it("falls back when " .. backend .. " cannot load the library", function()
            options.missing_library = true
            local selected, reason = k4tls.select(backend)
            assert.is_nil(selected)
            assert.truthy(reason:find("not loadable", 1, true))
            assert.equals(2, #state.loads)
            assert.equals("k4tls", state.loads[1])
            assert.truthy(state.loads[2]:find("/libk4tls.so", 1, true))
            assert.equals(0, state.cdefs)
        end)
    end
    it("uses an explicit environment override and fails safe on unknown values", function()
        env = "k4tls"
        assert.equals(k4tls, k4tls.select("luasec"))
        env = "typo"
        assert.is_nil(k4tls.select("k4tls"))
        env = "luasec"
        assert.is_nil(k4tls.select("auto"))
    end)
    it("ignores an empty environment override", function()
        env = ""
        assert.equals(k4tls, k4tls.select("auto"))
    end)
    it("returns nil,error when ffi is unavailable", function()
        package.preload.ffi = function() error("stub: ffi unavailable") end
        local first, err, third = request()
        failure(first, err, third, "unavailable")
        assert.equals(0, #state.loads)
        assert.equals(0, state.performs)
        assert.equals(0, state.frees)
    end)
    it("returns nil,error when the library is unavailable", function()
        options.missing_library = true
        local first, err, third = request()
        failure(first, err, third, "unavailable")
        assert.equals(0, state.performs)
        assert.equals(0, state.frees)
    end)
    for _, url in ipairs({ "http://stub.invalid/", "file:///stub", "", false }) do
        it("rejects non-HTTPS URL " .. tostring(url) .. " before reading the source", function()
            local first, err, third = request({ url = url, source = function() error("source read") end })
            failure(first, err, third, "non-https")
            assert.equals(0, state.performs)
            assert.equals(0, state.frees)
        end)
    end
    it("rejects a missing URL with nil,error", function()
        local first, err, third = k4tls.request({})
        failure(first, err, third, "non-https")
        assert.equals(0, state.performs)
    end)
    it("copies a binary response by explicit length before freeing and sends EOF", function()
        options.body = "a\0b\0"
        options.headers = "Location: https://stub.invalid/next\r\nX-Test: value\r\n"
        local chunks, calls = {}, 0
        local first, code, headers, status = request({ sink = function(chunk, err)
            calls = calls + 1
            assert.is_nil(err)
            assert.equals(1, state.frees)
            if calls == 1 then
                assert.equals(options.body, chunk)
                chunks[#chunks + 1] = chunk
            else
                assert.equals(2, calls)
                assert.is_nil(chunk)
            end
            return 1
        end })
        assert.equals(1, first)
        assert.equals(200, code)
        assert.equals("https://stub.invalid/next", headers.Location)
        assert.equals("value", headers["X-Test"])
        assert.is_nil(status)
        assert.equals(options.body, table.concat(chunks))
        assert.equals(2, calls)
        assert.equals(1, state.strings)
        assert.equals(0, state.copies)
        released()
    end)
    it("sends just EOF for an empty response", function()
        local calls = 0
        local first, code = request({ sink = function(chunk, err)
            calls = calls + 1
            assert.is_nil(chunk)
            assert.is_nil(err)
            return 1
        end })
        assert.equals(1, first)
        assert.equals(200, code)
        assert.equals(1, calls)
        released()
    end)
    it("succeeds without a sink and frees the response", function()
        options.body = "a\0b"
        local first, code = request()
        assert.equals(1, first)
        assert.equals(200, code)
        released()
    end)
    it("passes HTTP error statuses through as HTTP responses", function()
        options.status = 503
        local first, code = request()
        assert.equals(1, first)
        assert.equals(503, code)
        released()
    end)
    it("marshals binary source, headers and budgets without enabling custom trust", function()
        local parts, index = { "ab", "\0cd" }, 0
        local first = request({ method = "POST", headers = { Cookie = "a=1", Host = "ignored" },
            block_timeout = 1.25, total_timeout = 3.5, transport_max_bytes = 4096,
            source = function() index = index + 1; return parts[index] end })
        assert.equals(1, first)
        local req = state.request
        assert.equals("https://stub.invalid/path", req.url.bytes)
        assert.equals("POST", req.method.bytes)
        assert.equals("ab\0cd", req.body.bytes)
        assert.equals(5, req.body_len)
        assert.equals(1, req.nheaders)
        assert.equals("Cookie: a=1", req.headers[0].bytes)
        assert.equals(1250, req.block_timeout_ms)
        assert.equals(3500, req.total_timeout_ms)
        assert.equals(4096, req.max_response_bytes)
        assert.is_nil(req.trust_pem)
        assert.equals(0, req.trust_pem_len)
        released()
    end)
    it("uses the existing default request budgets and an empty body", function()
        assert.equals(1, request())
        assert.equals("GET", state.request.method.bytes)
        assert.is_nil(state.request.body)
        assert.equals(0, state.request.body_len)
        assert.equals(8000, state.request.block_timeout_ms)
        assert.equals(16000, state.request.total_timeout_ms)
        assert.equals(8 * 1024 * 1024, state.request.max_response_bytes)
    end)
    for _, case in ipairs({ { -11, "connection refused" }, { -13, "timeout" },
        { -17, "certificate verify failed" }, { -16, "binary response exceeds the 1024-byte limit" } }) do
        it("returns nil,error and frees status " .. case[1], function()
            options.status, options.detail = case[1], "stub detail"
            local first, err, third = request({ transport_max_bytes = 1024,
                sink = function() error("sink must not be called") end })
            failure(first, err, third, case[2])
            if case[1] ~= -16 then assert.truthy(err:find("stub detail", 1, true)) end
            released()
        end)
    end
    for _, rc in ipairs({ -1, -99 }) do
        it("returns nil,error without freeing or finalizing rc " .. rc, function()
            options.rc, options.detail = rc, "stub failure"
            local first, err, third = request({ sink = function() error("sink must not be called") end })
            failure(first, err, third, "rc=" .. tostring(rc))
            assert.truthy(err:find("stub failure", 1, true))
            assert.equals(0, state.frees)
            assert.equals(0, state.attaches)
            assert.equals(0, state.detaches)
        end)
    end
    for _, field in ipairs({ "body", "headers", "err" }) do
        it("frees and detaches when copying " .. field .. " raises", function()
            options.body, options.headers, options.copy_error = "a\0b", "X: y", field
            local ok, err = pcall(request)
            assert.is_false(ok)
            assert.truthy(tostring(err):find("stub copy failure: " .. field, 1, true))
            released()
        end)
    end
    it("propagates a source error and discards partial chunks", function()
        local calls = 0
        local body, err = k4tls.source_to_body(function()
            calls = calls + 1
            if calls == 1 then return "partial" end
            return nil, "source failed"
        end)
        assert.is_nil(body)
        assert.equals("source failed", err)
        assert.equals(2, calls)
    end)
    for _, partial in ipairs({ false, true }) do
        it("does not perform a request after a source error (partial=" .. tostring(partial) .. ")", function()
            local calls = 0
            local first, err, third = request({ source = function()
                calls = calls + 1
                if partial and calls == 1 then return "partial" end
                return nil, "source failed"
            end, sink = function() error("sink must not be called") end })
            failure(first, err, third, "source failed")
            assert.equals(partial and 2 or 1, calls)
            assert.equals(0, state.performs)
            assert.equals(0, state.frees)
        end)
    end
    it("propagates a source exception without performing a request", function()
        local ok, err = pcall(request, { source = function() error("source raised") end })
        assert.is_false(ok)
        assert.truthy(tostring(err):find("source raised", 1, true))
        assert.equals(0, state.performs)
        assert.equals(0, state.frees)
    end)
    for _, stage in ipairs({ "body", "EOF" }) do
        it("propagates a sink failure at " .. stage .. " without further calls", function()
            options.body = "body"
            local calls = 0
            local first, err, third = request({ sink = function(chunk)
                calls = calls + 1
                if stage == "body" or chunk == nil then return nil, "sink failed: " .. stage end
                return 1
            end })
            failure(first, err, third, "sink failed: " .. stage)
            assert.equals(stage == "body" and 1 or 2, calls)
            released()
        end)
        it("propagates a sink exception at " .. stage .. " after freeing", function()
            options.body = "body"
            local calls = 0
            local ok, err = pcall(request, { sink = function(chunk)
                calls = calls + 1
                if stage == "body" or chunk == nil then error("sink raised: " .. stage) end
                return 1
            end })
            assert.is_false(ok)
            assert.truthy(tostring(err):find("sink raised: " .. stage, 1, true))
            assert.equals(stage == "body" and 1 or 2, calls)
            released()
        end)
    end
    it("filters reserved headers and keeps stable header order", function()
        local list, count = k4tls.headers_table_to_list({ Cookie = "a=1", Accept = "*/*",
            Host = "x", ["cOnTeNt-LeNgTh"] = "5", Connection = "close",
            ["Transfer-Encoding"] = "chunked", Invalid = 2 })
        assert.equals(2, count)
        assert.equals("Accept: */*", list[1])
        assert.equals("Cookie: a=1", list[2])
    end)
    it("parses headers with original case and the last duplicate value", function()
        local headers = k4tls.headers_blob_to_table("Location: /next\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n")
        assert.equals("/next", headers.Location)
        assert.equals("b=2", headers["Set-Cookie"])
        assert.is_nil(next(k4tls.headers_blob_to_table(nil)))
    end)
    it("keeps retry classifier error vocabulary", function()
        for _, case in ipairs({ { -10, "host or service not provided" }, { -11, "connection refused" },
            { -13, "timeout" }, { -15, "closed" }, { -17, "certificate" } }) do
            assert.truthy(k4tls.error_text(case[1]):find(case[2], 1, true))
        end
    end)

    if ffi_ok and type(real_ffi) == "table" and real_ffi.new then
        it("uses real LuaJIT cdata for binary copying and finalizer detachment", function()
            local body, headers, frees, copies, calls = nil, nil, 0, 0, 0
            local lib = {}
            local ffi = setmetatable({}, { __index = real_ffi })
            ffi.load = function() return lib end
            ffi.string = function(ptr, len)
                assert.equals(0, frees)
                if body and ptr == body then
                    assert.equals(4, len)
                    copies = copies + 1
                end
                if len then return real_ffi.string(ptr, len) end
                return real_ffi.string(ptr)
            end
            ffi.copy = function() error("must use ffi.string(ptr, len)") end
            function lib.k4tls_perform(req, resp)
                assert.equals(0, tonumber(req.trust_pem_len))
                body = real_ffi.new("unsigned char[4]", "a\0b\0")
                headers = real_ffi.new("char[?]", 7, "X: yes")
                resp.status, resp.body, resp.body_len = 200, body, 4
                resp.headers_blob = headers
                return 0
            end
            function lib.k4tls_free_response(resp)
                frees = frees + 1
                real_ffi.fill(body, 4, 120)
                real_ffi.fill(headers, 7, 120)
                resp.body, resp.headers_blob, resp.body_len = nil, nil, 0
            end
            package.loaded.ffi = ffi
            local first, code, response_headers = request({ sink = function(chunk)
                calls = calls + 1
                assert.equals(1, frees)
                if calls == 1 then assert.equals("a\0b\0", chunk) else assert.is_nil(chunk) end
                return 1
            end })
            collectgarbage("collect")
            collectgarbage("collect")
            assert.equals(1, first)
            assert.equals(200, code)
            assert.equals("yes", response_headers.X)
            assert.equals(1, copies)
            assert.equals(1, frees)
            assert.equals(2, calls)
        end)
    end
end)
