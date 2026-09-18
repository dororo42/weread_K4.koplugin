-- Unit tests for ProgressSync:_fetch_remote (B6 gateway-first pull,
-- 2026-09-18 §六·2). The function is exercised through a minimal receiver
-- double (settings + client), asserting the channel SELECTION contract:
--
--   * with an API key configured, the gateway (Bearer, cookie-free) result
--     returns immediately and the pure-cookie web channel is NEVER probed
--     -- that probe was a guaranteed -2012 with an expired cookie session
--     (extra radio round-trip + log noise on the K4);
--   * the web channel is a FALLBACK only: no API key, gateway transport
--     error, or a gateway API-error body;
--   * the P1-D reason contract survives: when every channel fails, the
--     gateway error (errCode=-2012 ...) wins over the web error.
--
-- normalize_remote runs for real (pure-Lua position_mapper) with minimal
-- gateway-shaped responses.
local PS = require("weread.lib.progress_sync")

describe("progress_sync._fetch_remote gateway-first pull", function()
    -- Minimal valid progress payload: find_progress_node() accepts a top
    -- level node carrying progress + bookId.
    local function payload(percent, updated_at)
        return {
            bookId = "b1",
            progress = percent,
            chapterUid = "1",
            chapterIdx = 1,
            chapterOffset = 10,
            updateTime = updated_at or 1000,
            summary = "chapter",
        }
    end

    -- Receiver double: settings decide channel availability, client records
    -- which channels were probed and what they answered.
    local function make_self(opts)
        opts.probes = { gateway = 0, web = 0 }
        return {
            settings = {
                is_api_configured = function() return opts.api == true end,
                is_cookie_configured = function() return opts.cookie == true end,
            },
            client = {
                get_progress = function()
                    opts.probes.gateway = opts.probes.gateway + 1
                    if opts.gateway_result then
                        return opts.gateway_result
                    end
                    error(opts.gateway_error or "gateway transport down", 0)
                end,
                get_web_progress = function()
                    opts.probes.web = opts.probes.web + 1
                    if opts.web_result then
                        return opts.web_result
                    end
                    error(opts.web_error or "web transport down", 0)
                end,
            },
        }, opts
    end

    it("returns the gateway result and never probes the web channel", function()
        local obj, opts = make_self({
            api = true, cookie = true,
            gateway_result = payload(42),
        })
        local remote, err = PS._fetch_remote(obj, "b1", {})
        assert.is_nil(err)
        assert.equals(42, remote.percent)
        assert.equals("gateway", remote.source)
        assert.equals(1, opts.probes.gateway)
        assert.equals(0, opts.probes.web) -- the B6 contract: no cookie probe
    end)

    it("falls back to web on a gateway transport error", function()
        local obj, opts = make_self({
            api = true, cookie = true,
            gateway_error = "connection refused",
            web_result = payload(50, 2000),
        })
        local remote, err = PS._fetch_remote(obj, "b1", {})
        assert.is_nil(err)
        assert.equals(50, remote.percent)
        assert.equals("web", remote.source)
        assert.equals(1, opts.probes.gateway)
        assert.equals(1, opts.probes.web)
    end)

    it("falls back to web when the gateway answers with an API error body", function()
        local obj, opts = make_self({
            api = true, cookie = true,
            gateway_result = { errCode = -2012, errMsg = "登录超时" },
            web_result = payload(60, 3000),
        })
        local remote, err = PS._fetch_remote(obj, "b1", {})
        assert.is_nil(err)
        assert.equals("web", remote.source)
        assert.equals(1, opts.probes.web)
    end)

    it("uses web only when no API key is configured", function()
        local obj, opts = make_self({
            api = false, cookie = true,
            web_result = payload(70, 4000),
        })
        local remote, err = PS._fetch_remote(obj, "b1", {})
        assert.is_nil(err)
        assert.equals("web", remote.source)
        assert.equals(0, opts.probes.gateway)
        assert.equals(1, opts.probes.web)
    end)

    it("reports remote_unavailable when no channel is configured", function()
        local obj = make_self({ api = false, cookie = false })
        local remote, err = PS._fetch_remote(obj, "b1", {})
        assert.is_nil(remote)
        assert.equals("remote_unavailable", err)
    end)

    it("prefers the gateway reason when both channels fail (P1-D)", function()
        local obj, opts = make_self({
            api = true, cookie = true,
            gateway_result = { errCode = -2012, errMsg = "登录超时" },
            web_result = { errCode = -2012, errMsg = "登录超时" },
        })
        local remote, err = PS._fetch_remote(obj, "b1", {})
        assert.is_nil(remote)
        assert.equals("gateway errCode=-2012 (登录超时)", err)
        assert.equals(1, opts.probes.gateway)
        assert.equals(1, opts.probes.web)
    end)

    it("falls back to the web reason when only the web channel is configured", function()
        local obj = make_self({
            api = false, cookie = true,
            web_result = { errCode = -2012, errMsg = "登录超时" },
        })
        local remote, err = PS._fetch_remote(obj, "b1", {})
        assert.is_nil(remote)
        assert.equals("web errCode=-2012 (登录超时)", err)
    end)
end)
