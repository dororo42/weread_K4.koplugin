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

-- F-06 (2026-10-05 audit): fixed-delay pull retries must not fire while the
-- device is known-offline — the crash log showed 50 scheduled / 11 exhausted
-- retries in 4 days firing into "Failed to restore Wi-Fi". The reconnect
-- event (on_network_connected) owns the offline case.
describe("progress_sync pull retry offline skip (F-06)", function()
    local function make_self(online)
        local scheduled = {}
        local pulled = {}
        local obj = {
            generation = 1,
            pull_retry_token = 5,
            verified = false,
            pulling = false,
            state = "unverified",
            current_book_id = "B1",
            settings = { get = function(_self, key, default)
                if key == "sync" then return { pull_on_open = true } end
                return default
            end },
            is_online = function() return online end,
            scheduler = {
                scheduleIn = function(_self, delay, fn)
                    scheduled[#scheduled + 1] = { delay = delay, fn = fn }
                end,
            },
            -- faithful to the real _pull contract: a plain pull bumps the
            -- retry token, invalidating any pending scheduled retry
            _pull = function(self2, opts)
                self2.pull_retry_token = self2.pull_retry_token + 1
                pulled[#pulled + 1] = opts
            end,
        }
        return setmetatable(obj, { __index = PS }), scheduled, pulled
    end

    it("skips the deferred retry while still offline", function()
        local obj, scheduled, pulled = make_self(false)
        obj:_schedule_pull_retry({ retry = 0 }, 5)
        assert.equals(1, #scheduled)
        scheduled[1].fn()
        assert.equals(0, #pulled)
    end)

    it("pulls when the link is back by retry time", function()
        local obj, scheduled, pulled = make_self(true)
        obj:_schedule_pull_retry({ retry = 0 }, 5)
        scheduled[1].fn()
        assert.equals(1, #pulled)
        assert.equals(false, pulled[1].manual)
    end)

    it("reconnect re-triggers the pull and invalidates stale retries", function()
        local obj, scheduled, pulled = make_self(true)
        obj:_schedule_pull_retry({ retry = 0 }, 5)
        obj:on_network_connected()
        -- on_network_connected pulled once (plain pull bumps the token, so
        -- the stale scheduled retry is a no-op even if it fires later)
        assert.equals(1, #pulled)
        assert.equals(6, obj.pull_retry_token)
        scheduled[1].fn()
        assert.equals(1, #pulled)
    end)
end)

-- W-2 (2026-10-26 unified review v2, welite report finding #3): the upload
-- chain now carries an account fingerprint. A snapshot captured under
-- account A must never be uploaded or applied after the credentials switch
-- to account B mid-flight (the async subprocess window / busy-retry loop).
describe("progress_sync upload account fingerprint (W-2)", function()
    local POSITION = { book_id = "B1", percent = 50 }

    -- Mutable credential store shared between the test and the double.
    local function make_self(creds, upload_backend)
        local scheduled = {}
        local obj = {
            generation = 1,
            uploading = false,
            state = "idle",
            current_book_id = "B1",
            now = function() return 1000 end,
            detect_book = function() return "B1" end,
            is_online = function() return true end,
            settings = {
                get = function(_self, key, default)
                    if key == "cookies" then return creds.cookies end
                    if key == "wr_ticket" then return creds.ticket end
                    if key == "wr_wrpa" then return creds.wrpa end
                    return default
                end,
            },
            read_report = {
                upload_position_async = upload_backend,
            },
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
        obj._persist = function(self2, book_id, patch)
            self2._persist_calls[#self2._persist_calls + 1] =
                { book_id = book_id, patch = patch }
        end
        return setmetatable(obj, { __index = PS }), scheduled
    end

    it("builds the fingerprint from sorted cookies + ticket + wrpa", function()
        local creds = {
            cookies = { wr_s = "b", wr_fp = "a" },
            ticket = "t1",
            wrpa = "p1",
        }
        local obj = make_self(creds, function() return true, "async" end)
        -- sorted: wr_fp before wr_s
        assert.equals("wr_fp=a;wr_s=b;ticket=t1;wrpa=p1", obj:_auth_fingerprint())
    end)

    it("returns nil (guard unavailable) when settings lack get()", function()
        local obj = {
            settings = {},
        }
        setmetatable(obj, { __index = PS })
        assert.is_nil(obj:_auth_fingerprint())
    end)

    it("aborts a busy retry when the account switched meanwhile", function()
        local creds = { cookies = { s = "a" }, ticket = "t", wrpa = "p" }
        local backend_calls = 0
        local obj, scheduled = make_self(creds, function()
            backend_calls = backend_calls + 1
            return false, { error_kind = "busy" }
        end)
        obj:_upload_snapshot(POSITION, "test", false)
        assert.equals(1, backend_calls)
        -- account switch between the first attempt and the busy retry
        creds.cookies = { s = "b" }
        scheduled[#scheduled].fn()
        assert.is_false(obj.uploading)      -- aborted, not left in flight
        assert.equals(1, backend_calls)     -- retry never re-entered the backend
    end)

    it("drops an accepted result that outlived its account", function()
        local creds = { cookies = { s = "a" }, ticket = "t", wrpa = "p" }
        local on_complete
        local obj = make_self(creds, function(_book, _book_id, _pos, _off, cb)
            on_complete = cb
            return true, "async"
        end)
        obj:_upload_snapshot(POSITION, "test", false)
        assert.is_true(obj.uploading) -- async job in flight owns the result
        creds.cookies = { s = "b" }
        on_complete(true, { accepted = true })
        assert.is_false(obj.uploading)
        -- the accepted result must NOT have been applied
        assert.not_equals("verified", obj.state)
        for _, call in ipairs(obj._persist_calls) do
            assert.is_nil(call.patch.last_uploaded_position)
        end
    end)

    it("applies the result normally when the account is unchanged", function()
        local creds = { cookies = { s = "a" }, ticket = "t", wrpa = "p" }
        local on_complete
        local obj = make_self(creds, function(_book, _book_id, _pos, _off, cb)
            on_complete = cb
            return true, "async"
        end)
        obj:_upload_snapshot(POSITION, "test", false)
        on_complete(true, { accepted = true })
        assert.equals("verified", obj.state)
        local last = obj._persist_calls[#obj._persist_calls]
        assert.is_not_nil(last.patch.last_uploaded_position)
    end)
end)

-- W-1 (2026-10-26 unified review v2, welite v1.0.6 lesson): a quick reopen
-- of the SAME book skips the open pull — the close path just uploaded (or
-- persisted) the freshest local position and the server may lag behind, so
-- an immediate full remote compare could throw the user back to a stale
-- remote position.
describe("progress_sync reopen continuity (W-1)", function()
    local POSITION = { book_id = "B1", percent = 42, chapter_uid = "c1" }

    local function make_self(opts)
        local scheduled = {}
        local obj = {
            generation = 0,
            pulling = false,
            uploading = false,
            verified = false,
            dirty = false,
            state = "idle",
            current_book_id = nil,
            now = function() return opts.now or 1000 end,
            _last_closed_book = opts.last_closed_book,
            _last_closed_at = opts.last_closed_at,
            detect_book = function() return "B1" end,
            get_book = function() return nil end, -- no upload backlog
            capture_local = function()
                return opts.position or POSITION, nil
            end,
            settings = {
                get = function(_self, key, default)
                    if key == "sync" then return { pull_on_open = true } end
                    return default
                end,
            },
            is_online = function() return true end,
            scheduler = {
                scheduleIn = function(_self, delay, fn)
                    scheduled[#scheduled + 1] = { delay = delay, fn = fn }
                end,
            },
            notify = function() end,
        }
        obj._persist_calls = {}
        obj._persist = function(self2, book_id, patch)
            self2._persist_calls[#self2._persist_calls + 1] =
                { book_id = book_id, patch = patch }
        end
        obj._pulled = {}
        obj._pull = function(self2, pull_opts)
            self2._pulled[#self2._pulled + 1] = pull_opts
        end
        return setmetatable(obj, { __index = PS }), scheduled
    end

    it("skips the open pull when the same book reopens within the window", function()
        local obj, scheduled = make_self({
            last_closed_book = "B1",
            last_closed_at = 990, -- 10s before "now"
        })
        obj:on_reader_ready()
        scheduled[1].fn()
        assert.equals(0, #obj._pulled)          -- open pull skipped
        assert.equals("unverified", obj.state)  -- honestly unconfirmed
        assert.equals("B1", obj.current_book_id)
        assert.equals(42, obj.local_position.percent)
    end)

    it("pulls when a different book reopens immediately", function()
        local obj, scheduled = make_self({
            last_closed_book = "OTHER",
            last_closed_at = 999,
        })
        obj:on_reader_ready()
        scheduled[1].fn()
        assert.equals(1, #obj._pulled)
        assert.is_false(obj._pulled[1].manual)
    end)

    it("pulls when the reopen exceeds the continuity window", function()
        local obj, scheduled = make_self({
            last_closed_book = "B1",
            last_closed_at = 900, -- 100s before "now" (> 30s window)
        })
        obj:on_reader_ready()
        scheduled[1].fn()
        assert.equals(1, #obj._pulled)
    end)

    it("pulls when the book was never closed in this session", function()
        local obj, scheduled = make_self({})
        obj:on_reader_ready()
        scheduled[1].fn()
        assert.equals(1, #obj._pulled)
    end)

    it("still persists the freshly captured position on a skipped pull", function()
        local obj, scheduled = make_self({
            last_closed_book = "B1",
            last_closed_at = 995,
            position = { book_id = "B1", percent = 55, chapter_uid = "c2" },
        })
        obj:on_reader_ready()
        scheduled[1].fn()
        local persisted = false
        for _, call in ipairs(obj._persist_calls) do
            if call.patch.last_local_position
                and call.patch.last_local_position.percent == 55 then
                persisted = true
            end
        end
        assert.is_true(persisted)
    end)
end)
