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

-- P1 (2026-09-29 audit Y-3): _upload_snapshot destructures the pcall result
-- of upload_position_async, which returns TWO values — (true, "async") for a
-- spawned subprocess job, (false, {error_kind="busy"}) while the report tick
-- holds the pipeline, (accepted, outcome) on inline completion. The old
-- two-value destructuring bound ret2's "async" tag to nothing: the
-- wait-for-callback and busy-retry branches were unreachable and
-- self.uploading was reset while an async job was still in flight.
describe("progress_sync._upload_snapshot pcall destructuring (audit Y-3)", function()
    local POSITION = { book_id = "B1", percent = 50 }

    -- Minimal receiver double: _upload_snapshot is exercised directly, with
    -- the upload backend stubbed to return one of the three result shapes.
    local function make_self(upload_backend)
        local scheduled = {}
        local obj = {
            generation = 1,
            uploading = false,
            state = "idle",
            current_book_id = "B1",
            now = function() return 1000 end,
            detect_book = function() return "B1" end,
            is_online = function() return true end,
            read_report = {
                upload_position_async = upload_backend,
            },
            -- _upload_snapshot calls self.run_online(...) with DOT syntax
            -- (matching the main.lua injection signature), so no self here.
            run_online = function(_label, cb)
                cb()
                return true
            end,
            scheduler = {
                scheduleIn = function(_self, delay, fn)
                    scheduled[#scheduled + 1] = { delay = delay, fn = fn }
                end,
            },
            notify = function() end,
        }
        obj._persist_calls = {}
        obj._persist = function(self, book_id, patch)
            self._persist_calls[#self._persist_calls + 1] = { book_id = book_id, patch = patch }
        end
        -- Method lookups (e.g. self:_upload_snapshot) resolve through the
        -- real module table; the fields above override per test.
        return setmetatable(obj, { __index = PS }), scheduled
    end

    it("keeps uploading=true while an async job is in flight", function()
        local obj = make_self(function() return true, "async" end)
        obj:_upload_snapshot(POSITION, "test", false)
        -- Regression: the old code reset uploading here even though the
        -- subprocess job was still running and on_complete owns the result.
        assert.is_true(obj.uploading)
        assert.equals("uploading", obj.state)
    end)

    it("schedules a busy retry while the report pipeline holds the job", function()
        local obj, scheduled = make_self(function() return false, { error_kind = "busy" } end)
        obj:_upload_snapshot(POSITION, "test", false)
        assert.equals(1, #scheduled)
        assert.equals(2, scheduled[1].delay) -- BUSY_RETRY_SECONDS
        assert.is_true(obj.uploading)        -- still waiting to retry
    end)

    it("gives up after the busy retry limit without staying in uploading", function()
        local obj, scheduled = make_self(function() return false, { error_kind = "busy" } end)
        obj:_upload_snapshot(POSITION, "test", false)
        -- attempts=1 ran synchronously; drive the retries to the limit.
        for _i = 1, 9 do
            scheduled[#scheduled].fn()
        end
        assert.equals(9, #scheduled)
        assert.is_false(obj.uploading)
        assert.equals("error", obj.state)
    end)

    it("resets uploading after an inline completion", function()
        local obj = make_self(function()
            -- Inline shape: on_complete already ran inside
            -- upload_position_async; returns (accepted, outcome).
            return false, { accepted = false, error = "HTTP 500" }
        end)
        obj:_upload_snapshot(POSITION, "test", false)
        assert.is_false(obj.uploading)
    end)

    it("reports an error when the upload backend itself throws", function()
        local obj = make_self(function() error("backend exploded") end)
        obj:_upload_snapshot(POSITION, "test", false)
        assert.is_false(obj.uploading)
        assert.equals("error", obj.state)
        local last = obj._persist_calls[#obj._persist_calls]
        assert.is_not_nil(last.patch.last_sync_error:find("backend exploded", 1, true))
    end)
end)
