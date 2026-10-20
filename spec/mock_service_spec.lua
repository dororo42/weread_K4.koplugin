-- B-3 (2026-10-20 audit, ported from welite's mock service design):
-- CI-grade regression against a REAL server. The Python fault-injection
-- gateway (dev/mock_gateway.py) serves slow/dropping/empty responses and
-- these specs drive weread.lib.client's REAL luasocket transport at it via
-- Client.set_test_origin — no stubbed socket.http anywhere in this file.
--
-- Acceptance from the report: "上报后断连 → 重启 → 补传" must be exercised
-- over an actual transport, not only via socket.http stubs (client_redirect_
-- spec covers the stubbed semantics; this file covers the wire).
--
-- Everything real (socket, socket.http, ltn12, json) and everything stubbed
-- elsewhere (socketutil, ipv4_dns, logger, bit) is installed LAZILY in the
-- run phase and CLEARLY torn down — the preload factories other specs leave
-- behind during busted's load phase would otherwise shadow the real stack
-- (same trap as protocol_spec).
local SERVER_PORT = tonumber(os.getenv("WEREAD_MOCK_PORT")) or 18473
local SERVER_ORIGIN = "http://127.0.0.1:" .. SERVER_PORT

local __SHARED = { client = nil, pid = nil }
local __STACK_NAMES = {
    "ltn12", "socket", "socket.http", "socketutil", "json",
    "weread.lib.client", "weread.lib.ipv4_dns", "weread.lib.logger",
    "weread.lib.protocol", "weread.lib.cookie", "weread.lib.plugin_util",
    "weread.lib.settings", "bit", "ffi/util", "weread.lib.i18n",
}

-- 32-bit bitwise emulation (plain Lua 5.1 has no bit library; protocol.lua
-- requires it). Same domain as spec/protocol_spec.lua's harness.
local function install_bit_emulation()
    local bit = {}
    local function bxor(a, b)
        local result, weight = 0, 1
        a, b = math.floor(a), math.floor(b)
        for _ = 1, 32 do
            local x, y = a % 2, b % 2
            if x ~= y then result = result + weight end
            a, b = (a - x) / 2, (b - y) / 2
            weight = weight * 2
        end
        return result
    end
    local function band(a, b)
        local result, weight = 0, 1
        a, b = math.floor(a), math.floor(b)
        for _ = 1, 32 do
            if a % 2 == 1 and b % 2 == 1 then result = result + weight end
            a, b = (a - a % 2) / 2, (b - b % 2) / 2
            weight = weight * 2
        end
        return result
    end
    bit.bxor = bxor
    bit.band = band
    bit.lshift = function(x, n) return (math.floor(x) * 2 ^ n) % 4294967296 end
    package.preload["bit"] = function() return bit end
    package.loaded["bit"] = bit
end

local function clear_stack()
    for _, name in ipairs(__STACK_NAMES) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

local function install_real_stack()
    clear_stack()
    -- KOReader's socketutil is unavailable. client.lua needs exactly:
    -- set_timeout / reset_timeout / table_sink. The stub makes the BLOCK
    -- deadline real through luasocket's own mechanism: http.lua applies
    -- `c:settimeout(_M.TIMEOUT)` to every connection (overriding anything
    -- the socket carries), so the stub drives socket.http.TIMEOUT per
    -- request instead. (The F-21 TOTAL deadline's cross-chunk accounting
    -- stays a device-side socketutil concern, covered by the stubbed specs.)
    local real_http = require("socket.http")
    local default_timeout = real_http.TIMEOUT
    package.preload["socketutil"] = function()
        return {
            set_timeout = function(_self, block, _total)
                -- http.lua reads its OWN module table (`_M.TIMEOUT`), so the
                -- override must land on the real module, not a wrapper.
                real_http.TIMEOUT = tonumber(block) or default_timeout
            end,
            reset_timeout = function()
                real_http.TIMEOUT = default_timeout
            end,
            table_sink = function(t)
                return function(chunk, err)
                    if chunk then table.insert(t, chunk) end
                    return true, err
                end
            end,
        }
    end
    -- Keep the real DNS resolver untouched; only the classifier is needed.
    package.preload["weread.lib.ipv4_dns"] = function()
        return { is_resolution_error = function() return false end }
    end
    package.preload["weread.lib.logger"] = function()
        return {
            warn = function() end, info = function() end, err = function() end,
        }
    end
    package.preload["ffi/util"] = function()
        return { template = function(text) return text end }
    end
    package.preload["weread.lib.i18n"] = function()
        return { tr = function(text) return text end }
    end
    install_bit_emulation()
    -- json / ltn12 / socket / socket.http resolve to the REAL luasocket and
    -- luajson rocks now that every shadowing preload is gone.
    local Client = require("weread.lib.client")
    Client.set_test_origin(SERVER_ORIGIN)
    __SHARED.client = Client
    return Client
end

local function new_client()
    local Client = __SHARED.client or install_real_stack()
    return Client:new({
        get = function(_self, _key, default) return default end,
        merge_set_cookie = function() end,
    })
end

-- Admin helpers (use the client itself against /__admin/*).
local function admin_reset()
    new_client():post_json(SERVER_ORIGIN .. "/__admin/reset", {})
end
local function admin_mode(patch)
    new_client():post_json(SERVER_ORIGIN .. "/__admin/mode", patch)
end
local function admin_requests()
    local client = new_client()
    local text = client:get_text(SERVER_ORIGIN .. "/__admin/requests", {})
    return client:json_decode(text).requests
end

local function start_server()
    if __SHARED.pid then return end
    local handle = io.popen(
        "nohup python3 dev/mock_gateway.py --port " .. SERVER_PORT
        .. " >/dev/null 2>&1 & echo $!", "r")
    __SHARED.pid = handle:read("*l")
    handle:close()
    -- Poll for readiness (bounded): the socket must accept within ~5s.
    local socket = require("socket")
    local deadline = socket.gettime() + 5
    while socket.gettime() < deadline do
        local tcp = socket.tcp()
        local ok = tcp:connect("127.0.0.1", SERVER_PORT)
        tcp:close()
        if ok then return end
        socket.sleep(0.1)
    end
    error("mock gateway did not come up on port " .. SERVER_PORT)
end

local function stop_server()
    if __SHARED.pid then
        os.execute("kill " .. __SHARED.pid .. " 2>/dev/null")
        __SHARED.pid = nil
    end
end

describe("mock gateway: real transport against dev/mock_gateway.py", function()
    -- Once per describe: bring the stack + server up (busted 2.x: setup runs
    -- once before all its in this context; teardown once after all).
    setup(function()
        -- Install FIRST (clears the load-phase preload stubs so socket/json
        -- resolve real), then bring the server up.
        install_real_stack()
        start_server()
        admin_reset()
    end)

    teardown(function()
        if __SHARED.client then
            __SHARED.client.set_test_origin(nil)
        end
        __SHARED.client = nil
        clear_stack()
        stop_server()
    end)

    it("round-trips a read report over the real socket stack", function()
        local client = new_client()
        local data = client:post_json("https://weread.qq.com/web/book/read",
            { bookId = "MP_WXS_mock", synckey = 1 })
        assert.equals(1, tonumber(data.succ))
        -- The gateway must have actually received it.
        local requests = admin_requests()
        assert.equals(1, #requests)
        assert.equals("/web/book/read", requests[1].path)
        assert.is_not_nil(requests[1].body:find("MP_WXS_mock", 1, true))
    end)

    it("classifies a dropped connection as transient, then resend succeeds (断连→补传)", function()
        admin_mode({ mode = "drop" })
        local client = new_client()
        local ok, err = pcall(client.post_json, client,
            "https://weread.qq.com/web/book/read", { tick = 1 })
        assert.is_falsy(ok)
        -- F-23 retryable class: "closed", not a timeout, not a silent success.
        assert.is_not_nil(tostring(err):lower():find("closed", 1, true))
        -- 补传: after the server recovers, the SAME payload goes through and
        -- the gateway's log shows exactly the replayed push.
        admin_mode({ mode = "ok" })
        admin_reset()  -- mode stays ok, log cleared for exact counting
        local data = client:post_json("https://weread.qq.com/web/book/read",
            { tick = 2 })
        assert.equals(1, tonumber(data.succ))
        local requests = admin_requests()
        assert.equals(1, #requests)
        assert.is_not_nil(requests[1].body:find("tick", 1, true))
    end)

    it("bounds a slow drip with the F-21 total deadline (no freeze)", function()
        admin_mode({ mode = "slow", delay_ms = 5000 })
        local client = new_client()
        local socket = require("socket")
        local started = socket.gettime()
        local ok, err = pcall(client.post_json, client,
            "https://weread.qq.com/web/book/read", { tick = 3 },
            { timeout = { 0.3, 0.6 } })
        local elapsed = socket.gettime() - started
        assert.is_falsy(ok)
        assert.is_not_nil(tostring(err):lower():find("timeout", 1, true))
        -- The 5s drip must NOT have been waited out.
        assert.is_true(elapsed < 4)
    end)

    it("degrades cleanly on an empty 200 body", function()
        admin_mode({ mode = "empty" })
        local client = new_client()
        local text, code = client:get_text("https://weread.qq.com/web/book/read", {})
        assert.equals(200, tonumber(code))
        assert.equals("", text)
        -- Decoding the empty body yields nothing usable (luajson returns nil)
        -- without crashing the transport layer.
        local ok_decode, decoded = pcall(client.json_decode, client, text)
        assert.is_true(ok_decode)
        assert.is_nil(decoded)
    end)

    it("surfaces an injected HTTP error status", function()
        admin_mode({ mode = "error", status = 502 })
        local client = new_client()
        -- get_text raises a diagnostic error on non-2xx (by design) — the
        -- injected status must reach the caller, not be swallowed.
        local ok, err = pcall(client.get_text, client,
            "https://i.weread.qq.com/api/agent/gateway", {})
        assert.is_falsy(ok)
        assert.is_not_nil(tostring(err):find("502", 1, true))
    end)

    it("rewrites the bare origin and subdomains, and only weread hosts", function()
        admin_mode({ mode = "ok" })
        admin_reset()
        local client = new_client()
        client:get_text("https://weread.qq.com/web/book/getProgress?bookId=x", {})
        client:get_text("https://i.weread.qq.com/api/agent/gateway", {})
        -- A non-weread origin must NOT be routed to the mock: connecting to
        -- a refused loopback port fails fast and leaves the log untouched.
        assert.is_falsy(pcall(client.get_text, client, "http://127.0.0.1:1/x", {}))
        local requests = admin_requests()
        assert.equals(2, #requests)
        assert.equals("/web/book/getProgress?bookId=x", requests[1].path)
        assert.equals("/api/agent/gateway", requests[2].path)
    end)
end)
