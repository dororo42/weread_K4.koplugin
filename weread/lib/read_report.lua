local Content = require("weread.lib.content")
local WeRead = require("weread.lib.protocol")
local PluginUtil = require("weread.lib.plugin_util")

local logger = require("weread.lib.logger").scoped("ReadReport")

local DEFAULT_INTERVAL_SECONDS = 30
-- K4 tuning: 30s default interval (was 45) tightens the tick window for more
-- uniform pacing now that subprocess fork is disabled (inline uploads).
local MIN_INTERVAL_SECONDS = 10
-- P0-2 (2026-08-26 翻页卡滞修复): page-turn deconfliction. A report tick
-- that lands while the user is turning pages blocks the UI loop (inline
-- LuaSocket + disk writes), which reads as page-turn stutter. When the last
-- page update was less than PAGE_DEFER_WINDOW_SECONDS ago, the tick is
-- postponed PAGE_DEFER_DELAY_SECONDS; after PAGE_DEFER_LIMIT consecutive
-- postponements (~30s of continuous page-turning) the tick runs anyway so
-- reading time keeps flowing (watermark semantics unchanged).
local PAGE_DEFER_WINDOW_SECONDS = 2
local PAGE_DEFER_DELAY_SECONDS = 5
local PAGE_DEFER_LIMIT = 6
-- P0-3a (2026-08-26 翻页卡滞修复): weak-network timeout degradation.
-- client.lua's default per-request timeout is 8s (DEFAULT_TIMEOUT_SECONDS);
-- on a phone-hotspot cellular path (Kindle -> hotspot WiFi is fine, the
-- cellular leg stalls) a stalled tick can freeze the UI loop for seconds.
-- After FAILURE_DEGRADE_THRESHOLD consecutive report failures the report
-- request timeout drops to FAILURE_DEGRADE_TIMEOUT; one success restores
-- the default. Normal (fast) links never hit the threshold, so the degrade
-- only ever engages where the link is actually bad.
local FAILURE_DEGRADE_THRESHOLD = 2
local FAILURE_DEGRADE_TIMEOUT = 4
-- P0-1 (2026-09-05): second-level degrade. A failure streak this long means
-- the link is effectively dead; 2s caps the worst-case per-request freeze
-- even lower while the streak lasts (one success restores the default).
local FAILURE_DEGRADE_DEEP_THRESHOLD = 5
local FAILURE_DEGRADE_DEEP_TIMEOUT = 2
-- S-12 (2026-09-05): a sustained failure streak means the link is dead or
-- stalling; stretch the tick cadence to 120s so retries stop colliding with
-- page turns. Reading time is never lost — the watermark covers the gap.
local WEAK_NETWORK_FAILURE_THRESHOLD = 4
local WEAK_NETWORK_TICK_SECONDS = 120
-- P2 (2026-08-26): tick cost instrumentation. time.now() (ms) so on-device
-- logs can quantify UI-loop freezes per tick (failed ticks and slow ticks).
local ok_time, time = pcall(require, "ui/time")
if not ok_time then
    time = nil
end

local CONTEXT_TTL_SECONDS = 15 * 60
local RENEWAL_COOLDOWN_SECONDS = 10 * 60
local JOB_POLL_INITIAL_SECONDS = 0.25
local JOB_POLL_MAX_SECONDS = 2
local JOB_TIMEOUT_SECONDS = 180
local JOB_COLLECT_INTERVAL_SECONDS = 2
-- Sleep windows longer than this are excluded from reading time. 30s is a
-- deliberate compromise: normal scheduler jitter on the K4 (GC/e-ink refresh/
-- wifi reconnect can delay ticks 10-30s) must NOT be misread as sleep, which
-- would drop real reading time (unrecoverable under-report). 30s leaves that
-- jitter headroom, while any real sleep (cover-close / auto-suspend) is far
-- above 30s, so short cover-closes are still excluded.
local SUSPEND_EXCLUDE_THRESHOLD_SECONDS = 30
-- Cross-session backlog carry-over (pending_backlog_seconds): instead of
-- restoring a raw watermark across sessions (which forced an impossible
-- choice between "drop real offline reading time" and "report sleep/away
-- time as reading time"), stop() snapshots the unsent reading-time backlog
-- accumulated up to last_active_at, and start() re-attaches it before now.
-- Effect: offline reading time is preserved across close/reopen regardless
-- of the gap, while the close→reopen gap itself is never counted as reading
-- time (it sits after last_active_at, outside the snapshot window).
-- last_active_at is still maintained per-book for the snapshot computation
-- and for on_resume's watermark advancement.
-- After this many consecutive ticks spent waiting for progress verification,
-- stop blocking the report and send with a nil position instead. Prevents an
-- unverified progress state from silently disabling offline time reporting.
local WAITING_LIMIT = 12
-- WeRead's /web/book/read endpoint accepts the per-report reading duration
-- (the `rt` field) in small increments only — the web reader heartbeats every
-- 30s, and oversized `rt` values are silently dropped server-side. Accumulated
-- offline time must therefore be sent as many small reports instead of one big
-- one. MAX_SINGLE_REPORT_SECONDS mirrors the web heartbeat; BACKLOG_TICK_SECONDS
-- is the throttled pace used while catching up on accumulated offline time.
local MAX_SINGLE_REPORT_SECONDS = 30
-- Backlog drain pace. Lower = faster catch-up but more radio wake-ups (battery);
-- raised from 4s to 10s to reduce battery drain on the K4 after reconnect, at
-- the cost of slower (but lossless — the watermark keeps the unreported time)
-- catch-up. Reading time is never lost; it is simply reported in more, smaller
-- increments over a longer window.
-- 2026-08-24 conservative review R-B: raised 15s -> 30s to match the real
-- heartbeat exactly. Draining a backlog at 2x the browser's heartbeat rate is
-- an un-browser-like request pattern (risk flag) and wakes the K4 radio twice
-- as often. At 30s the drain cadence is identical to normal reading, costs no
-- extra wake-ups, and reading time is still never lost (watermark keeps it).
local BACKLOG_TICK_SECONDS = 30
-- K4 tuning: raised from 10s to 15s to further reduce radio wake-ups on the
-- K4's weak WiFi, at the cost of slower (but lossless) catch-up.

-- Context fields that the subprocess sends back for the parent to persist.
-- Mirrors the scalar reading-state fields stored by BookStore; the chapter
-- catalog itself stays in the on-disk catalog cache written by the child.
local CONTEXT_FIELDS = {
    "title", "reader_url", "app_id", "psvts", "pclts", "token",
    "chapter_uid", "chapter_idx", "chapter_offset", "progress", "summary",
    "read_context_updated_at", "read_session_entered_at", "read_session_id",
}

local ReadReport = {}
ReadReport.__index = ReadReport

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function book_record(books, book_id)
    if type(books) ~= "table" then
        return nil
    end
    return books[tostring(book_id)] or books[book_id]
end

local function response_body(result)
    if type(result) ~= "table" then
        return result
    end
    if result.succ ~= nil or result.synckey ~= nil then
        return result
    end
    if type(result.data) == "table" then
        return result.data
    end
    if type(result.result) == "table" then
        return result.result
    end
    return result
end

local function table_keys(value)
    if type(value) ~= "table" then
        return ""
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    return table.concat(keys, "|")
end

local function response_accepted(result, http_code)
    local body = response_body(result)
    if WeRead.is_success_response(body) then
        return true, body
    end
    if type(body) ~= "table" then
        return false, body
    end
    if body.synckey ~= nil then
        return true, body
    end
    local error_code = body.errCode or body.errcode or body.errorCode
        or result.errCode or result.errcode or result.errorCode
    if error_code ~= nil then
        return false, body
    end
    return false, body
end

local function full_response_body(client, result)
    if type(result) == "table" and client and type(client.json_encode) == "function" then
        local ok, encoded = pcall(function()
            return client:json_encode(result)
        end)
        if ok then
            return encoded
        end
    end
    return tostring(result)
end

local function response_summary(client, result, http_code)
    if type(result) ~= "table" then
        return "non_table_response, http=" .. tostring(http_code)
            .. ", response_body=" .. full_response_body(client, result)
    end
    local body = response_body(result)
    local parts = {
        "http=" .. tostring(http_code),
        "keys=" .. table_keys(result),
        "body_keys=" .. table_keys(body),
        "succ=" .. tostring(type(body) == "table" and body.succ or nil),
        "has_synckey=" .. tostring(type(body) == "table" and body.synckey ~= nil or false),
    }
    local code = type(body) == "table" and (body.errCode or body.errcode or body.code)
        or result.errCode or result.errcode or result.code
    local message = type(body) == "table" and (body.errMsg or body.errmsg or body.message or body.msg)
        or result.errMsg or result.errmsg or result.message or result.msg
    if code ~= nil then
        parts[#parts + 1] = "error_code=" .. tostring(code)
    end
    if message ~= nil then
        parts[#parts + 1] = "error_message="
            .. tostring(message):gsub("[%c]+", " "):sub(1, 160)
    end
    -- Only rejected reading reports call this function. Keep the complete
    -- decoded response in the failure log so unexpected server replies can be
    -- diagnosed without enabling verbose logging for successful reports.
    -- S-01 (2026-09-05): redact credential-looking values first.
    parts[#parts + 1] = "response_body="
        .. PluginUtil.redact_body(full_response_body(client, result))
    return table.concat(parts, ", ")
end

function ReadReport:new(options)
    options = options or {}
    assert(options.settings, "read report settings are required")
    assert(options.client, "read report client is required")
    assert(options.scheduler, "read report scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        library_db = options.library_db,
        scheduler = options.scheduler,
        get_document = options.get_document,
        detect_book = options.detect_book,
        position_provider = options.position_provider,
        is_online = options.is_online or function() return true end,
        now = options.now or os.time,
        session_id = tostring({}) .. ":" .. tostring((options.now or os.time)()),
        -- K4：禁用子进程 fork（fork 导致 UI 卡顿 0.5-3s），全部上传走
        -- inline（见 K4_v2.5_P0待改项_子进程fork卡顿.md）。S-13 (2026-09-05)
        -- 已删除永不启用的 make_subprocess_runner 死代码；若未来恢复 fork，
        -- 在此重新注入 runner。
        state = "stopped",
        generation = 0,
        count = 0,
        failure_count = 0,
        consecutive_failures = 0,
        waiting_count = 0,
        started_at = nil,
        -- Watermark of reading time already accepted by the server. Reading
        -- advances it in MAX_SINGLE_REPORT_SECONDS steps; time between the
        -- watermark and now is the unsent backlog (offline accumulation).
        watermark = nil,
        -- Per-book watermark bookkeeping (S-2/S-3 fix): watermark and
        -- last_active_at are persisted per-book (in read_report.watermarks
        -- keyed by book_id) so switching books doesn't inherit the old book's
        -- backlog.
        last_active_at = nil,
        watermark_book_id = nil,
        -- Cross-session pending backlog (pending_backlog fix): when stop()
        -- runs, the unsent reading time accumulated up to last_active_at
        -- (i.e. max(0, last_active_at - watermark)) is snapshotted into
        -- pending_backlog_seconds and persisted per-book. On the next
        -- start() for the same book, the watermark is initialized to
        -- (now - pending_backlog_seconds), re-attaching the offline
        -- reading time in front of now so it can be drained by ticks.
        -- The close→reopen gap (after last_active_at) is never included.
        -- Cleared once ticks drain the backlog to zero.
        pending_backlog_seconds = nil,
        -- P0-3: set when a report was server-rejected with renewal on
        -- cooldown; forces the next ensure_context() to rebuild (deferred
        -- refresh instead of an in-tick retry chain).
        _context_stale = false,
        _context_stale_book = nil,
    }
    return setmetatable(object, self)
end

function ReadReport:_config()
    return self.settings:get("read_report")
end

function ReadReport:_interval()
    local interval = tonumber(self:_config().interval_seconds) or DEFAULT_INTERVAL_SECONDS
    return math.max(MIN_INTERVAL_SECONDS, interval)
end

-- Seconds to put in the next report's `rt` field. The server only honours
-- small increments (the web reader sends ~30s heartbeats), so a long offline
-- stretch must be drained as a series of small reports rather than one big
-- value that the server would silently discard. The amount still unsent is
-- (now - watermark); see start()/_record_success for watermark bookkeeping.
function ReadReport:_next_report_seconds()
    local base = self.watermark or self.started_at or self.now()
    local backlog = math.max(0, self.now() - base)
    if backlog > 0 then
        return math.min(MAX_SINGLE_REPORT_SECONDS, backlog)
    end
    return math.min(MAX_SINGLE_REPORT_SECONDS, self:_interval())
end

-- Exponential backoff for repeated report failures (2026-08-24 review R-C).
-- The pipeline already fires up to 4 requests per tick; without a backoff a
-- weak network would keep draining at BACKLOG_TICK pace into a ~16 req/min
-- storm, and failed-request bursts look more suspicious than success bursts.
-- Ramp: 30s -> 60s -> 120s -> ... capped at 300s. _record_success() resets
-- consecutive_failures, so the backoff clears as soon as a report is accepted.
-- P1-2 (2026-08-26 翻页卡滞修复): cap lowered 300s -> 60s. With the P0-3
-- retry-chain slimming, a failed tick now costs at most one request, so a
-- shorter ramp no longer risks a request storm; the old 120-300s gaps showed
-- up on-device as "stutter every 1-2 minutes" pacing that collided with page
-- turns. Watermark still guarantees no reading time is lost.
local function backoff_delay(consecutive_failures)
    if consecutive_failures <= 0 then
        return nil
    end
    return math.min(60, 30 * math.floor(2 ^ (consecutive_failures - 1)))
end

-- Tick cadence: normally one report per interval; while a backlog of unsent
-- reading time remains, tick at BACKLOG_TICK to drain it at a throttled pace.
-- After a failure the backoff takes precedence, so repeated failures never
-- hammer the server or drain the battery in a request storm.
function ReadReport:_next_tick_delay()
    local consecutive = self.consecutive_failures or 0
    local interval = self:_interval()
    -- S-12: sustained failure streak — stretch the cadence before the
    -- backoff ramp so retries stop colliding with page turns.
    if consecutive >= WEAK_NETWORK_FAILURE_THRESHOLD then
        return WEAK_NETWORK_TICK_SECONDS
    end
    local backoff = backoff_delay(consecutive)
    if backoff then
        return backoff
    end
    if not self.watermark then
        return interval
    end
    if self.now() - self.watermark > interval then
        return BACKLOG_TICK_SECONDS
    end
    return interval
end

function ReadReport:status()
    return {
        running = self.task ~= nil,
        state = self.state,
        count = self.count or 0,
        failure_count = self.failure_count or 0,
        consecutive_failures = self.consecutive_failures or 0,
        last_time = self.last_time,
        last_error = self.last_error,
        last_error_kind = self.last_error_kind,
        stop_reason = self.stop_reason,
        target_book_id = self.current_book_id,
        target_book_title = self.current_book_title,
        target_source = self.current_book_source,
        -- Unsent (e.g. accumulated offline) reading time still being drained.
        backlog_seconds = self.watermark
            and math.max(0, self.now() - self.watermark) or nil,
    }
end

function ReadReport:resolve_target()
    local config = self:_config()
    local has_document = self.get_document() ~= nil
    if config.mode == "manual"
        and tostring(config.book_id or "") ~= ""
        and (has_document or config.report_on_open == false) then
        return tostring(config.book_id),
            tostring(config.book_title or "") ~= "" and config.book_title or tostring(config.book_id),
            "manual"
    end

    if not has_document then
        return nil, nil, "no_document"
    end

    local detected_id = self.detect_book()
    if detected_id then
        detected_id = tostring(detected_id)
        -- Avoid reloading every book record from disk on each tick just for
        -- the title; reuse the cached one while the target stays the same.
        if detected_id == self.current_book_id
            and tostring(self.current_book_title or "") ~= "" then
            return detected_id, self.current_book_title, "current_document"
        end
        local book = book_record(self.settings:get("books", {}), detected_id)
        return detected_id,
            type(book) == "table" and book.title or detected_id,
            "current_document"
    end
    return nil, nil, "document_not_weread"
end

function ReadReport:_set_error(err, kind, prefix)
    local message = tostring(err)
    self.last_error = message
    self.last_error_kind = kind or "error"
    self.failure_count = (self.failure_count or 0) + 1
    self.consecutive_failures = (self.consecutive_failures or 0) + 1
    self.state = "error"
    if self.logged_error ~= message then
        log("warn", prefix or "read report error:", message)
        self.logged_error = message
    end
end

function ReadReport:_record_success(result)
    local recovered = self.last_error ~= nil
    self.count = (self.count or 0) + 1
    self.last_time = self.now()
    self.last_error = nil
    self.last_error_kind = nil
    self.logged_error = nil
    self.last_skip = nil
    self.consecutive_failures = 0
    self.state = "active"
    if recovered or self.count == 1 or self.count % 20 == 0 then
        log("info", "read report success:",
            "count=", self.count,
            "has_synckey=", type(result) == "table" and result.synckey ~= nil or false)
    end
end

function ReadReport:_log_skip(reason)
    if self.last_skip ~= reason then
        log("info", "read report skipped:", reason)
        self.last_skip = reason
    end
end

function ReadReport:maybe_start(reason)
    local config = self:_config()
    if not config.enabled then
        self:_log_skip("disabled")
        return false, nil, "disabled"
    end
    if self.suspended then
        self.state = "suspended"
        self:_log_skip("suspended")
        return false, nil, "suspended"
    end
    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        self:_log_skip(source)
        return false, nil, source
    end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    if self.task then
        return true, title, source
    end
    return self:start(reason), title, source
end

function ReadReport:start(reason)
    if self.task then
        return true
    end
    local book_id, title, source = self:resolve_target()
    if not self:_config().enabled or self.suspended or not book_id then
        return false
    end

    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    self.state = "waiting"
    self.stop_reason = nil
    self.last_skip = nil
    -- New session: reset failure state so the R-C backoff does not carry a
    -- stale ramp from a previous session into the first ticks (e.g. a weak
    -- network that recovered overnight would otherwise still wait 300s).
    self.consecutive_failures = 0
    -- Start the accumulation clock. watermark tracks how much reading time the
    -- server has already accepted; while the device is offline the tick leaves
    -- it intact, so once back online the backlog is drained as a series of
    -- small reports (the server discards oversized single reports).
    -- Cross-session carry-over (pending_backlog fix): stop() snapshots the
    -- unsent reading time up to last_active_at into pending_backlog_seconds
    -- (per-book). start() re-attaches it by setting
    --   watermark = now - pending_backlog_seconds
    -- which puts the preserved offline reading time in front of now so ticks
    -- can drain it, while the close→reopen gap (after last_active_at) is
    -- never counted. last_time keeps meaning "last successful report at"
    -- for the status UI.
    self.last_time = nil
    local config = self:_config()
    local now = self.now()
    -- Per-book pending backlog carry-over (S-2/S-3/pending_backlog fix):
    -- watermarks[book_id] holds { watermark, last_active, pending_backlog }.
    -- On start() we only consume pending_backlog: it is the offline reading
    -- time accumulated up to last_active_at at the previous stop(). The
    -- watermark is rebuilt as (now - pending_backlog), which represents
    -- "server-accepted time is pending_backlog seconds behind now". The
    -- previous raw watermark value is intentionally NOT restored — restoring
    -- it would re-introduce the close→reopen gap as reading time.
    local watermarks = type(config.watermarks) == "table" and config.watermarks or {}
    local entry = watermarks[tostring(book_id)]
    local pending = entry and tonumber(entry.pending_backlog)
    if pending and pending > 0 then
        -- Re-attach the preserved offline reading time in front of now.
        -- Cap at a conservative 3h (2026-08-24 review R-A, was 24h): normal
        -- offline reading (weak-network reconnect, overnight airplane-mode
        -- reading) stays far below 3h, and pending_backlog is consumed and
        -- cleared on each start(), so it never accumulates across sessions.
        -- Anything beyond 3h is either corrupted (flipped clock / malformed
        -- config) or an un-human 24h-style stretch a single web session could
        -- never produce — drop the excess rather than report it (reporting
        -- 24h at once is a classic abnormal-usage flag server-side).
        local cap = 3 * 3600
        local capped = math.min(pending, cap)
        if pending > cap then
            log("warn", "pending backlog exceeds conservative cap, dropping excess:",
                "pending=", tostring(pending), "cap=", tostring(cap))
        end
        self.watermark = now - capped
        self.pending_backlog_seconds = capped
    else
        -- No pending backlog: start fresh at now.
        self.watermark = now
        self.pending_backlog_seconds = nil
    end
    self.last_active_at = now
    self.watermark_book_id = book_id
    -- Migration: clean up the legacy global watermark field.
    if config.watermark ~= nil then
        config.watermark = nil
        pcall(function() self.settings:set("read_report", config) end)
    end
    self.started_at = now
    self.waiting_count = 0
    -- P0-3: a new session must not inherit a stale-context flag (the
    -- deferred refresh belongs to the previous session's book).
    self._context_stale = false
    self._context_stale_book = nil

    local task
    task = function()
        if self.generation ~= generation or self.task ~= task then
            return
        end
        self:_tick(generation, task)
    end
    self.task = task
    local interval = self:_interval()
    self.next_tick_expected = self.now() + interval
    self.scheduler:scheduleIn(interval, task)
    log("info", "reading time report started:",
        "reason=", reason or "unknown",
        "book_id=", book_id,
        "source=", source)
    return true
end

function ReadReport:stop(reason)
    reason = reason or "unspecified"
    local had_task = self.task ~= nil
    self.generation = self.generation + 1
    if self.task then
        self.scheduler:unschedule(self.task)
        self.task = nil
    end
    if self.job then
        -- Try to collect any already-completed result before abandoning (H-7 fix)
        local runner = self.subprocess
        if runner and self.job.read_fd then
            local readable = runner.read_size(self.job.read_fd)
            if readable and readable > 0 then
                local payload = runner.read_all(self.job.read_fd)
                self.job.read_fd = nil
                local outcome = self:_decode_outcome(payload)
                if outcome then
                    self:_apply_job_outcome(self.job, outcome)
                    self.job = nil
                end
            end
        end
        if self.job then
            self:_abandon_job(self.job)
        end
    end
    self.next_tick_expected = nil
    self.state = reason == "suspend" and "suspended"
        or "stopped"
    self.stop_reason = reason
    -- Persist the watermark and snapshot the unsent reading time accumulated
    -- up to last_active_at into pending_backlog_seconds (pending_backlog fix).
    -- On the next start() for this book, pending_backlog is re-attached in
    -- front of now, preserving offline reading time across close/reopen
    -- regardless of the gap, while the gap itself is never counted.
    self:_persist_watermark()
    -- Force flush on stop to ensure watermark is persisted (M-L9 fix)
    if self._watermark_flush_pending then
        self._watermark_flush_pending = false
        pcall(function() self.settings:flush() end)
    end
    -- P0-1B: force any deferred report-context flush before teardown so a
    -- stopped report never leaves the last position write on disk.
    if self._context_flush_pending then
        self._context_flush_pending = false
        pcall(function() self.settings:flush() end)
    end
    -- S-05 (2026-09-05): release the coalesced-flush timers. stop() used to
    -- leave them scheduled, keeping this instance alive up to 30s after
    -- teardown; the forced flushes above already persisted everything.
    if self._watermark_flush_fn then
        self.scheduler:unschedule(self._watermark_flush_fn)
        self._watermark_flush_scheduled = false
        self._watermark_flush_fn = nil
    end
    if self._context_flush_fn then
        self.scheduler:unschedule(self._context_flush_fn)
        self._context_flush_scheduled = false
        self._context_flush_fn = nil
    end
    if had_task then
        log("info", "reading time report stopped:",
            "reason=", reason,
            "success_count=", self.count or 0,
            "failure_count=", self.failure_count or 0)
    end
end

function ReadReport:on_reader_ready()
    self.suspended = false
    return self:maybe_start("reader_ready")
end

function ReadReport:on_suspend()
    self.suspended = true
    self.suspended_at = self.now()
    self:stop("suspend")
end

function ReadReport:on_resume()
    self.suspended = false
    -- Advance watermark past the sleep duration so suspend time is not
    -- reported as reading time (H-4 fix). Advancing watermark here shrinks
    -- the (last_active_at - watermark) gap, which _persist_watermark()
    -- reflects in pending_backlog — so suspend time is also excluded from
    -- the cross-session snapshot (pending_backlog fix).
    if self.suspended_at and self.watermark then
        local sleep_duration = self.now() - self.suspended_at
        if sleep_duration > SUSPEND_EXCLUDE_THRESHOLD_SECONDS then
            self.watermark = math.min(self.now(), self.watermark + sleep_duration)
            -- Refresh last_active_at to now: the resume itself is the most
            -- recent reading activity boundary. _persist_watermark() uses
            -- last_active_at to compute pending_backlog = max(0,
            -- last_active_at - watermark); keeping it fresh ensures the
            -- snapshot covers exactly the pre-suspend reading time, not
            -- the sleep window.
            self.last_active_at = self.now()
            self:_persist_watermark()
        end
    end
    self.suspended_at = nil
    return self:maybe_start("resume")
end

function ReadReport:on_close_document()
    local config = self:_config()
    if config.report_on_open ~= false or config.mode == "auto" then
        self:stop("document_closed")
        self.current_book_id = nil
        self.current_book_title = nil
        self.current_book_source = nil
        return
    end
    self:maybe_start("document_closed_background")
end

-- ------------------------------------------------------------------
-- Scheduled tick: cheap parent-side checks, then hand the network
-- pipeline to a subprocess (or run it inline as a fallback).
-- ------------------------------------------------------------------

function ReadReport:_schedule_next(generation, task, delay)
    if self.generation == generation and self.task == task then
        delay = delay or self:_interval()
        self.next_tick_expected = self.now() + delay
        self.scheduler:scheduleIn(delay, task)
    end
end

function ReadReport:_tick(generation, task)
    -- Refresh last_active_at on every tick (pending_backlog fix): as long as
    -- the report task is running (document open), the user is considered
    -- active. This timestamp bounds the pending_backlog snapshot at stop()
    -- to exactly the reading time accumulated so far, excluding any gap
    -- after the last tick.
    self.last_active_at = self.now()
    -- Detect undetected suspend: if the tick fired much later than expected,
    -- the device was likely sleeping without onSuspend firing. Reset
    -- last_time so the accumulated sleep duration is not reported as reading.
    if self.next_tick_expected then
        local delay = self.now() - self.next_tick_expected
        if delay > SUSPEND_EXCLUDE_THRESHOLD_SECONDS then
            log("info", "read report tick delayed beyond threshold, likely suspend:",
                "delay=", delay, "threshold=", SUSPEND_EXCLUDE_THRESHOLD_SECONDS)
            -- Drop only the sleep window (the delayed tick gap), keeping the
            -- backlog accumulated before the suspend: resetting the watermark
            -- to now would silently discard offline reading time too.
            local now = self.now()
            self.watermark = math.min(now,
                (self.watermark or now) + math.max(0, delay))
            self:_persist_watermark()
        end
    end
    self.next_tick_expected = nil
    -- P2: wall-clock cost of this tick (ms) for on-device diagnosis of
    -- UI-loop freezes (failed ticks and slow ticks are logged below).
    local tick_started_ms = time and time.now() or 0
    local ok, err = pcall(function()
        local proceed, book_id, position = self:_precheck()
        if not proceed then
            self:_schedule_next(generation, task)
            return
        end
        -- P0-2: page-turn deconfliction. A report tick is pure UI-loop work
        -- (inline HTTP + book-record writes); firing it mid page-turn is what
        -- the user perceives as stutter. Postpone while pages are being
        -- turned, with a hard ceiling so continuous reading never starves
        -- the report.
        if self:_recent_page_update() then
            self:_schedule_next(generation, task, PAGE_DEFER_DELAY_SECONDS)
            return
        end
        -- S-03: never fabricate reading time after a wall-clock rollback
        -- (see _clock_rolled_back).
        if self:_clock_rolled_back() then
            log("warn", "clock rollback detected, skipping this report tick:",
                "now=", tostring(self.now()),
                "watermark=", tostring(self.watermark))
            self:_schedule_next(generation, task)
            return
        end
        if self.job then
            -- Previous report is still in flight; keep the cadence and let
            -- the poller reschedule once it completes.
            self:_schedule_next(generation, task, self:_next_tick_delay())
            return
        end
        local allow_renewal = self:_renewal_allowed()
        local elapsed_seconds = self:_next_report_seconds()
        local spawned, spawn_err = self:_start_job(
            book_id, allow_renewal, generation, task, position, elapsed_seconds)
        if spawned then
            return
        end
        if not self.logged_inline_fallback then
            log("warn", "read report subprocess unavailable, reporting inline:",
                tostring(spawn_err))
            self.logged_inline_fallback = true
        end
        local outcome = self:_run_pipeline(book_id, {
            allow_renewal = allow_renewal,
            position = position,
            elapsed_seconds = elapsed_seconds,
        })
        -- P2: log every failed tick's cost (and slow successes >= 1s) so a
        -- crash.log session can quantify how long the UI loop froze and how
        -- many requests a failure actually burned (P0-3 validation).
        if time then
            local elapsed_ms = time.now() - tick_started_ms
            if outcome and not outcome.accepted then
                log("warn", "read report tick failed:",
                    "elapsed_ms=", tostring(elapsed_ms),
                    "error_kind=", tostring(outcome.error_kind or "unknown"),
                    "error=", tostring(outcome.error or "unknown"))
            elseif elapsed_ms >= 1000 then
                log("info", "read report tick slow:",
                    "elapsed_ms=", tostring(elapsed_ms))
            end
        end
        self:_apply_outcome(outcome)
        self:_schedule_next(generation, task, self:_next_tick_delay())
    end)
    if not ok then
        self:_set_error(err, "task", "read report task failed:")
        self:_schedule_next(generation, task)
    end
end

-- P0-3a helper: degraded per-request timeout while the report pipeline is
-- in a failure streak (see constants above). Returns nil (= client default
-- 8s) on healthy links.
function ReadReport:_request_timeout()
    local failures = self.consecutive_failures or 0
    if failures >= FAILURE_DEGRADE_DEEP_THRESHOLD then
        return FAILURE_DEGRADE_DEEP_TIMEOUT
    end
    if failures >= FAILURE_DEGRADE_THRESHOLD then
        return FAILURE_DEGRADE_TIMEOUT
    end
    return nil
end

-- S-03 (2026-09-05): wall-clock rollback guard. Domain math (watermark,
-- backlog) runs on os.time(); if the wall clock jumped backwards past the
-- watermark (NTP correction / manual adjust), reporting would fabricate
-- reading time — an anomaly the server can observe. The tick caller skips
-- sending; the watermark keeps the already-accumulated time.
function ReadReport:_clock_rolled_back()
    return self.watermark ~= nil and self.now() < self.watermark
end

-- P0-2 helper: true when the reader turned a page within the defer window.
-- The host injects get_last_page_update (main.lua -> reader_lifecycle's
-- onPageUpdate timestamp). Consecutive postponements are capped so a fast
-- continuous page-turner never starves the reading-time report.
function ReadReport:_recent_page_update()
    if type(self.get_last_page_update) ~= "function" then
        return false
    end
    local last = self.get_last_page_update()
    if not last or type(last) ~= "number" then
        return false
    end
    if self.now() - last < PAGE_DEFER_WINDOW_SECONDS then
        self._page_defers = (self._page_defers or 0) + 1
        if self._page_defers <= PAGE_DEFER_LIMIT then
            return true
        end
        self._page_defers = 0
    else
        self._page_defers = 0
    end
    return false
end

-- Parent-side gate before any network work. Returns true, book_id when a
-- report should be attempted. Must stay cheap: it runs on the UI loop.
function ReadReport:_precheck()
    local config = self:_config()
    if not config.enabled then
        self:stop("disabled")
        return false
    end
    if self.suspended then
        self:stop("suspend")
        return false
    end

    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        return false
    end
    if self.current_book_id and self.current_book_id ~= book_id then
        self:stop("document_changed")
        self:maybe_start("document_changed")
        return false
    end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source

    if not self.settings:is_cookie_configured() then
        self:_set_error("cookie not configured", "authentication", "read report skipped:")
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        self:_log_skip("offline")
        return false
    end
    local position
    if type(self.position_provider) == "function" then
        local provided, reason, applies = self.position_provider(book_id)
        if applies and not provided then
            self.waiting_count = (self.waiting_count or 0) + 1
            if self.waiting_count < WAITING_LIMIT then
                self.state = "waiting_for_progress"
                self:_log_skip(reason or "progress_unverified")
                return false
            end
            -- Give up waiting for progress verification: report with a nil
            -- position rather than silently dropping offline reading time.
            self.waiting_count = 0
            log("warn", "progress verification unavailable for too long; "
                .. "reporting without a verified position")
        else
            self.waiting_count = 0
        end
        position = provided
    end
    return true, book_id, position
end

function ReadReport:_renewal_allowed()
    return self.now() - (self.last_renew_attempt or 0) >= RENEWAL_COOLDOWN_SECONDS
end

function ReadReport:_auth_fingerprint()
    local cookies = self.settings:get("cookies", {}) or {}
    local keys = {}
    for key in pairs(cookies) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    local parts = {}
    for _i, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. tostring(cookies[key])
    end
    parts[#parts + 1] = "ticket=" .. tostring(self.settings:get("wr_ticket", ""))
    parts[#parts + 1] = "wrpa=" .. tostring(self.settings:get("wr_wrpa", ""))
    return table.concat(parts, ";")
end

function ReadReport:_context_fingerprint(book_id)
    local book = book_record(self.settings:get("books", {}), book_id) or {}
    local parts = {}
    for _i, field in ipairs(CONTEXT_FIELDS) do
        parts[#parts + 1] = field .. "=" .. tostring(book[field])
    end
    return table.concat(parts, ";")
end

-- ------------------------------------------------------------------
-- Subprocess job management (parent side)
-- ------------------------------------------------------------------

function ReadReport:_start_job(book_id, allow_renewal, generation, task, position, elapsed_seconds, on_complete)
    local runner = self.subprocess
    if not runner then
        return false, "no subprocess support"
    end
    local pid, read_fd = runner.run(function(_pid, child_write_fd)
        local outcome = self:_child_report(book_id, allow_renewal, position, elapsed_seconds)
        local ok, encoded = pcall(function()
            return self.client:json_encode(outcome)
        end)
        if not ok or type(encoded) ~= "string" then
            encoded = '{"accepted":false,"error":"failed to serialize report outcome",'
                .. '"error_kind":"job"}'
        end
        runner.write_all(child_write_fd, encoded)
    end)
    if not pid then
        return false, tostring(read_fd)
    end

    local job = {
        pid = pid,
        read_fd = read_fd,
        book_id = book_id,
        started_at = self.now(),
        poll_interval = JOB_POLL_INITIAL_SECONDS,
        auth_fingerprint = self:_auth_fingerprint(),
        context_fingerprint = self:_context_fingerprint(book_id),
    }
    job.poll = function()
        self:_poll_job(job, generation, task)
    end
    job.on_complete = on_complete
    self.job = job
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
    return true
end

function ReadReport:_poll_job(job, generation, task)
    if self.job ~= job then
        return
    end
    local runner = self.subprocess
    local done = runner.is_done(job.pid)
    local readable = job.read_fd and runner.read_size(job.read_fd)
    if done or (readable and readable > 0) then
        local payload
        if job.read_fd then
            payload = runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.job = nil
        if not done then
            -- Output was read while the child was still exiting; reap it in
            -- the background so it does not linger as a zombie.
            self:_collect_pid(job.pid)
        end
        self:_apply_job_outcome(job, self:_decode_outcome(payload))
        self:_schedule_next(generation, task, self:_next_tick_delay())
        return
    end
    if self.now() - job.started_at > JOB_TIMEOUT_SECONDS then
        log("warn", "read report job timed out, terminating:", "pid=", job.pid)
        self:_abandon_job(job)
        self:_set_error("report job timed out", "transport", "read report job failed:")
        self:_schedule_next(generation, task)
        return
    end
    job.poll_interval = math.min(job.poll_interval * 2, JOB_POLL_MAX_SECONDS)
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
end

-- Kill a running job and keep reaping until the child is collected, so a
-- stopped or timed-out report can never leave a zombie behind.
function ReadReport:_abandon_job(job)
    job = job or self.job
    if not job then
        return
    end
    if self.job == job then
        self.job = nil
    end
    local runner = self.subprocess
    if job.poll then
        self.scheduler:unschedule(job.poll)
    end
    runner.terminate(job.pid)
    local collect_attempts = 0
    local MAX_COLLECT_ATTEMPTS = 30  -- 30 * 2s = 60s upper bound (M-L6 fix)
    local collect
    collect = function()
        if runner.is_done(job.pid) then
            if job.read_fd then
                runner.read_all(job.read_fd)
                job.read_fd = nil
            end
            return
        end
        collect_attempts = collect_attempts + 1
        if collect_attempts > MAX_COLLECT_ATTEMPTS then
            log("warn", "zombie collection gave up after",
                tostring(MAX_COLLECT_ATTEMPTS * JOB_COLLECT_INTERVAL_SECONDS) .. "s",
                "pid=", tostring(job.pid))
            return
        end
        if job.read_fd and (runner.read_size(job.read_fd) or 0) ~= 0 then
            -- Drain the pipe so a child blocked on write() can exit.
            runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
    end
    collect()
end

function ReadReport:_collect_pid(pid)
    local runner = self.subprocess
    local collect_attempts = 0
    local MAX_COLLECT_ATTEMPTS = 30  -- 30 * 2s = 60s upper bound (M-L6 fix)
    local collect
    collect = function()
        if not runner.is_done(pid) then
            collect_attempts = collect_attempts + 1
            if collect_attempts <= MAX_COLLECT_ATTEMPTS then
                self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
            end
        end
    end
    self.scheduler:scheduleIn(1, collect)
end

function ReadReport:_decode_outcome(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        return self.client:json_decode(payload)
    end)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

-- ------------------------------------------------------------------
-- Outcome application (parent side)
-- ------------------------------------------------------------------

function ReadReport:_apply_job_outcome(job, outcome)
    local book_id = job.book_id
    if type(outcome) == "table" then
        if type(outcome.auth) == "table" then
            if self:_auth_fingerprint() ~= job.auth_fingerprint then
                log("info", "skip renewed auth write-back: parent auth changed during job")
            else
                local ok, err = pcall(function()
                    self.settings:update_auth({
                        cookies = outcome.auth.cookies,
                        wr_ticket = outcome.auth.wr_ticket,
                        wr_wrpa = outcome.auth.wr_wrpa,
                    }, { replace_cookies = true })
                end)
                if not ok then
                    log("warn", "persist renewed auth failed:", tostring(err))
                end
            end
        end
        if type(outcome.book) == "table" then
            if self:_context_fingerprint(book_id) ~= job.context_fingerprint then
                log("info", "skip report context write-back: parent record changed during job")
            else
                local ok, err = pcall(function()
                    self:_persist_context(book_id, outcome.book)
                end)
                if not ok then
                    log("warn", "persist report context failed:", tostring(err))
                end
            end
        end
    end
    local result = self:_apply_outcome(outcome)
    -- Notify the async caller (e.g. progress_sync upload_position_async) if registered
    if type(job.on_complete) == "function" then
        local accepted = type(outcome) == "table" and outcome.accepted == true
        local ok_cb, cb_err = pcall(job.on_complete, accepted, outcome)
        if not ok_cb then
            log("warn", "upload on_complete callback failed:", tostring(cb_err))
        end
    end
    return result
end

-- Persist the current per-book watermark and snapshot the unsent reading
-- time into pending_backlog so offline-accumulated reading time survives
-- document close / KOReader restart / suspend. Without this, start() resets
-- the watermark to now and the unsent backlog is silently dropped — the
-- root cause of "offline reading time never gets reported".
-- Watermarks are stored per-book in config.watermarks[book_id] (S-2 fix),
-- so switching books doesn't inherit the old book's backlog.
-- pending_backlog (pending_backlog fix) = max(0, last_active_at - watermark):
--   the unsent reading time accumulated up to the last reading activity.
--   On the next start() it is re-attached as (now - pending_backlog), so
--   the close→reopen gap is never counted while real offline reading time
--   is preserved regardless of how long the gap was.
function ReadReport:_persist_watermark()
    if not self.watermark then return end
    -- Use current_book_id if available, fall back to watermark_book_id
    -- (set in start()) so on_resume() can persist watermark advancement
    -- even after on_close_document() cleared current_book_id (S-4 fix).
    local book_id = tostring(self.current_book_id or self.watermark_book_id or "")
    if book_id == "" then return end
    local ok, config = pcall(function()
        return self.settings:get("read_report")
    end)
    if not ok or type(config) ~= "table" then return end
    local watermarks = type(config.watermarks) == "table" and config.watermarks or {}
    -- Snapshot the unsent reading time accumulated up to last_active_at.
    -- This is the value start() will re-attach in front of now. Using
    -- last_active_at (not now) is what excludes the close→reopen gap.
    local last_active = self.last_active_at or self.now()
    local pending = math.max(0, last_active - self.watermark)
    -- Keep self.pending_backlog_seconds in sync with the persisted value so
    -- _apply_outcome can clear it once the backlog is drained.
    self.pending_backlog_seconds = pending > 0 and pending or nil
    watermarks[book_id] = {
        watermark = self.watermark,
        last_active = last_active,
        pending_backlog = self.pending_backlog_seconds,
    }
    config.watermarks = watermarks
    -- Migration: clean up legacy global watermark field.
    config.watermark = nil
    local ok_set, err = pcall(function()
        self.settings:set("read_report", config)
    end)
    if not ok_set then
        log("warn", "persist read report watermark failed:", tostring(err))
        return
    end
    -- Coalesce flush: mark dirty and schedule a single deferred flush
    -- instead of writing on every tick (M-L9 fix).
    self._watermark_flush_pending = true
    if not self._watermark_flush_scheduled then
        self._watermark_flush_scheduled = true
        -- S-05 (2026-09-05): keep the closure reachable so stop() can
        -- unschedule it (previously an anonymous closure that pinned the
        -- instance for up to 30s after teardown).
        self._watermark_flush_fn = function()
            self._watermark_flush_scheduled = false
            self._watermark_flush_fn = nil
            if self._watermark_flush_pending then
                self._watermark_flush_pending = false
                pcall(function() self.settings:flush() end)
            end
        end
        self.scheduler:scheduleIn(30, self._watermark_flush_fn)
    end
end

function ReadReport:_apply_outcome(outcome)
    if type(outcome) ~= "table" then
        self:_set_error("report job returned no result", "job", "read report job failed:")
        return false
    end
    if outcome.renew_attempted then
        self.last_renew_attempt = self.now()
    end
    if outcome.accepted then
        -- Advance the watermark by the amount the server just accepted. The
        -- remaining (now - watermark) backlog is drained by the next ticks.
        -- _persist_watermark() recomputes pending_backlog = max(0,
        -- last_active_at - watermark); once the backlog is fully drained
        -- (watermark catches up to last_active_at), pending_backlog is
        -- cleared automatically (pending_backlog fix).
        if self.watermark and outcome.reported_seconds then
            self.watermark = self.watermark + outcome.reported_seconds
            self:_persist_watermark()
        end
        self:_record_success({ synckey = outcome.has_synckey and true or nil })
        return true
    end
    self:_set_error(outcome.error or "unknown report failure",
        outcome.error_kind or "error",
        outcome.error_prefix)
    return false
end

function ReadReport:_context_snapshot(book)
    local snapshot = { book_id = book.book_id }
    for _i, field in ipairs(CONTEXT_FIELDS) do
        snapshot[field] = book[field]
    end
    return snapshot
end

function ReadReport:_persist_context(book_id, snapshot)
    local books = self.settings:get("books", {})
    local book = book_record(books, book_id) or { book_id = book_id }
    local changed = false
    -- Replace semantics, not merge: a refreshed context may legitimately
    -- clear session fields (notably pclts), and the old wholesale record
    -- overwrite dropped them too. JSON strips nils from the outcome, so a
    -- missing snapshot field means "cleared".
    for _i, field in ipairs(CONTEXT_FIELDS) do
        local value = snapshot[field]
        if book[field] ~= value then
            book[field] = value
            changed = true
        end
    end
    if not changed then
        return
    end
    book.book_id = book.book_id or book_id
    books[book_id] = book
    self.settings:set_book(book_id, book)
    self:_schedule_context_flush()
end

-- P0-3 helper: flag the reader context as stale so the next
-- ensure_context() rebuilds it via the normal TTL path (instead of firing
-- refresh+retry inside the current tick, which used to block the UI loop
-- with up to 5 extra requests). Implemented as an instance flag, not a
-- book-field write: mutating read_context_updated_at in the cached record
-- could be overwritten by _persist_context (upload path) before the next
-- tick rebuilds, silently cancelling the deferral.
function ReadReport:_mark_context_stale(book_id)
    self._context_stale_book = book_id
end

-- P0-1B (2026-08-26 翻页卡滞修复): coalesced settings flush for report
-- context writes. Same pattern as the watermark flush: mark dirty, schedule
-- a single flush 30s later, force on stop(). Removes one full weread.lua
-- write per tick.
function ReadReport:_schedule_context_flush()
    self._context_flush_pending = true
    if self._context_flush_scheduled then return end
    self._context_flush_scheduled = true
    -- S-05 (2026-09-05): keep the closure reachable so stop() can unschedule.
    self._context_flush_fn = function()
        self._context_flush_scheduled = false
        self._context_flush_fn = nil
        if self._context_flush_pending then
            self._context_flush_pending = false
            pcall(function() self.settings:flush() end)
        end
    end
    self.scheduler:scheduleIn(30, self._context_flush_fn)
end

-- ------------------------------------------------------------------
-- Report pipeline (runs in the subprocess, or inline as fallback)
-- ------------------------------------------------------------------

-- Child entry point. Neuters settings persistence inside the fork and
-- captures auth changes (Set-Cookie merges, cookie renewal) so the parent
-- can persist them from the outcome.
function ReadReport:_child_report(book_id, allow_renewal, position, elapsed_seconds)
    self._no_persist = true
    self.settings.flush = function() end
    local auth_changed = false
    local original_update_auth = self.settings.update_auth
    self.settings.update_auth = function(settings_obj, credentials, options)
        auth_changed = true
        options = options or {}
        options.flush = false
        return original_update_auth(settings_obj, credentials, options)
    end

    local ok, outcome = pcall(function()
        return self:_run_pipeline(book_id, {
            allow_renewal = allow_renewal,
            position = position,
            elapsed_seconds = elapsed_seconds,
        })
    end)
    if not ok then
        outcome = {
            accepted = false,
            error = tostring(outcome),
            error_kind = "task",
            error_prefix = "read report task failed:",
        }
    end
    if auth_changed then
        outcome.auth = {
            cookies = self.settings:get("cookies", {}),
            wr_ticket = self.settings:get("wr_ticket", ""),
            wr_wrpa = self.settings:get("wr_wrpa", ""),
        }
    end
    return outcome
end

-- Full report attempt: context, send, refresh-retry, renewal, final retry.
-- Pure with respect to the parent state machine: everything the caller needs
-- is described by the returned outcome table.
function ReadReport:_run_pipeline(book_id, opts)
    opts = opts or {}
    local outcome = { accepted = false, renew_attempted = false }
    outcome.reported_seconds = opts.elapsed_seconds or self:_interval()

    local context_ok, book = pcall(function()
        return self:ensure_context(book_id, false)
    end)
    if not context_ok then
        outcome.error = tostring(book)
        outcome.error_kind = "context"
        outcome.error_prefix = "read report context initialization failed:"
        return outcome
    end
    local ok, result, http_code = pcall(function()
        return self:_send(
            book_id, book, opts.position, opts.elapsed_seconds)
    end)
    outcome.book = self:_context_snapshot(book)
    local accepted, accepted_body = response_accepted(result, http_code)
    if ok and accepted then
        outcome.accepted = true
        outcome.has_synckey = type(accepted_body) == "table"
            and accepted_body.synckey ~= nil or false
        return outcome
    end
    if not ok then
        outcome.error = tostring(result)
        outcome.error_kind = "transport"
        outcome.error_prefix = "read report request failed:"
        return outcome
    end

    local failure = response_summary(self.client, result, http_code)

    -- P0-3 (2026-08-26 翻页卡滞修复): slimming the in-tick retry chain.
    -- Previously a rejected send triggered refresh+retry and (with renewal
    -- allowed) renew+final in the SAME tick — up to 5 more blocking requests
    -- on the UI loop (each up to 8s) for one failed report. Now:
    --  * renewal recently attempted (!allow_renewal): give up on this tick
    --    and mark the context stale, so the NEXT tick's ensure_context()
    --    rebuilds it (TTL check) and retries there — refresh work is
    --    deferred, not dropped;
    --  * renewal allowed: skip the refresh+retry middle step (a stale psvts
    --    is rebuilt by the final ensure_context(force) anyway) and go
    --    straight to renew + final send. At most 2 extra requests, at most
    --    once per 10 minutes (RENEWAL_COOLDOWN_SECONDS), instead of up to 5
    --    on every failure.
    if not opts.allow_renewal then
        self:_mark_context_stale(book_id)
        outcome.error = failure
        outcome.error_kind = "server"
        outcome.error_prefix = "read report server rejected:"
        return outcome
    end
    outcome.renew_attempted = true

    local renew_ok, renew_result = pcall(function()
        return self.client:renew_cookie()
    end)
    if not renew_ok or not WeRead.is_success_response(renew_result) then
        outcome.error = failure .. "; renewal=" .. (renew_ok
            and response_summary(self.client, renew_result)
            or tostring(renew_result))
        outcome.error_kind = "authentication"
        outcome.error_prefix = "read report cookie renewal failed:"
        return outcome
    end

    local final_context_ok, final_book = pcall(function()
        return self:ensure_context(book_id, true)
    end)
    if not final_context_ok then
        outcome.error = failure .. "; final_context=" .. tostring(final_book)
        outcome.error_kind = "context"
        outcome.error_prefix = "read report final context refresh failed:"
        return outcome
    end
    outcome.book = self:_context_snapshot(final_book)
    local final_ok, final_result, final_code = pcall(function()
        return self:_send(
            book_id, final_book, opts.position, opts.elapsed_seconds)
    end)
    outcome.book = self:_context_snapshot(final_book)
    local final_accepted, final_body = response_accepted(final_result, final_code)
    if final_ok and final_accepted then
        outcome.accepted = true
        outcome.has_synckey = type(final_body) == "table"
            and final_body.synckey ~= nil or false
        return outcome
    end
    outcome.error = failure .. "; final=" .. (final_ok
        and response_summary(self.client, final_result, final_code)
        or tostring(final_result))
    outcome.error_kind = final_ok and "server" or "transport"
    outcome.error_prefix = "read report final retry failed:"
    return outcome
end

-- Inline (blocking) report used when subprocess support is unavailable.
function ReadReport:report_once()
    local proceed, book_id, position = self:_precheck()
    if not proceed then
        return false
    end
    local outcome = self:_run_pipeline(book_id, {
        allow_renewal = self:_renewal_allowed(),
        position = position,
    })
    return self:_apply_outcome(outcome)
end

-- ------------------------------------------------------------------
-- Report context
-- ------------------------------------------------------------------

function ReadReport:_merge_remote_progress(book_id, book)
    local ok, result = pcall(function()
        return self.client:get_progress(book_id)
    end)
    if not ok or type(result) ~= "table" then
        return
    end
    local remote = type(result.book) == "table" and result.book or result
    book.progress = tonumber(remote.progress) or tonumber(book.progress) or 0
    book.chapter_uid = remote.chapterUid or remote.chapterId or remote.chapter_uid or book.chapter_uid
    book.chapter_idx = tonumber(remote.chapterIdx or remote.chapterIndex or remote.chapter_idx)
        or tonumber(book.chapter_idx)
    book.chapter_offset = tonumber(remote.chapterOffset or remote.chapterPos or remote.offset)
        or tonumber(book.chapter_offset) or 0
    book.summary = remote.summary or book.summary or ""
end

-- Build (and refresh when stale) the reader context on the given book
-- record. Performs network I/O; never persists settings.
function ReadReport:_build_context(book_id, force, book)
    book.book_id = book.book_id or book.bookId or book_id
    book.reader_url = WeRead.reader_url(book_id)

    -- BookStore never persists the chapter list, so a freshly loaded record
    -- has no chapters. Restore them from the on-disk catalog cache (and the
    -- SQLite library_db when available) first; otherwise the TTL check below
    -- can never pass and every report would refetch the whole reader page.
    if type(book.chapters) ~= "table" or #book.chapters == 0 then
        Content.load_catalog_cache(self.client, self.settings, book)
    end
    if type(book.chapters) ~= "table" or #book.chapters == 0 then
        -- v4.0 (2.5): SQLite double-storage fallback before hitting the
        -- network (upstream library_db integration).
        local db = self.library_db
        local db_chapters = db and db:getChapters(book_id) or nil
        if type(db_chapters) == "table" and #db_chapters > 0 then
            book.chapters = db_chapters
        end
    end

    local age = self.now() - (tonumber(book.read_context_updated_at) or 0)
    local ready = tostring(book.psvts or "") ~= ""
        and book.chapter_uid ~= nil
        and type(book.chapters) == "table" and #book.chapters > 0
        and book.read_session_id == self.session_id
        -- P0-3: a rejected report flagged the context stale; force a rebuild
        -- even inside the TTL window so the deferred refresh actually happens
        -- on the next tick.
        and not self._context_stale
    if not force and ready and age < CONTEXT_TTL_SECONDS then
        return book
    end

    Content.ensure_reader_state(self.client, book)
    if book.pclts == nil or book.pclts == "" or tonumber(book.pclts) == 0 then
        book.pclts = WeRead.e(self.now())
    end
    book.read_session_entered_at = nil
    book.read_session_id = self.session_id
    if force or type(book.chapters) ~= "table" or #book.chapters == 0 then
        local chapters = Content.fetch_catalog(self.client, book)
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters)
        if not cache_ok then
            log("warn", "save chapter catalog cache failed:", tostring(cache_err))
        end
        -- v4.0 (2.5): mirror into the SQLite library_db so the offline
        -- fallback above can serve it on later sessions.
        -- P1-1 (2026-08-26 翻页卡滞修复): defer the SQLite mirror write out
        -- of the tick's critical path — putChapters opens the DB, runs schema
        -- PRAGMAs and inserts one row per chapter (hundreds of rows on large
        -- books), which blocked the UI loop for 0.5-2s. The on-disk catalog
        -- JSON written above is the authoritative cache; SQLite is only a
        -- secondary mirror, so a one-event-loop defer is safe.
        if self.library_db then
            self.scheduler:scheduleIn(0.1, function()
                pcall(function() self.library_db:putChapters(book_id, chapters) end)
            end)
        end
        book.chapters = chapters
    end
    self:_merge_remote_progress(book_id, book)

    local selected
    for _i, chapter in ipairs(book.chapters or {}) do
        if tostring(chapter.chapterUid or "") == tostring(book.chapter_uid or "") then
            selected = chapter
            break
        end
    end
    selected = selected or Content.first_readable_chapter(book.chapters)
    if not selected then
        error("no readable chapter found for report context")
    end
    book.chapter_uid = selected.chapterUid or book.chapter_uid
    book.chapter_idx = tonumber(selected.chapterIdx) or tonumber(book.chapter_idx) or 0
    book.app_id = book.app_id or WeRead.web_app_id()
    book.read_context_updated_at = self.now()
    if tostring(book.psvts or "") == "" or book.chapter_uid == nil then
        error("reader context is incomplete")
    end
    return book
end

function ReadReport:ensure_context(book_id, force)
    book_id = tostring(book_id or "")
    if book_id == "" then
        error("missing book id")
    end
    if not self.settings:is_cookie_configured() then
        error("cookie not configured")
    end

    local books = self.settings:get("books", {})
    local existing = book_record(books, book_id)
    local book = existing or {
        book_id = book_id,
        title = self.current_book_title or book_id,
    }
    -- P0-1A (2026-08-26 翻页卡滞修复): snapshot the persisted fields before
    -- building so an unchanged context (the common case for a 30s tick
    -- inside the TTL window) skips the full book-record write + settings
    -- flush that used to run unconditionally on every tick.
    local before = existing and self:_context_snapshot(existing) or nil
    self:_build_context(book_id, force, book)
    -- P0-3: any rebuild (fresh or forced) clears the stale flag; the
    -- deferred refresh has now happened (whichever book it was for).
    self._context_stale = false
    self._context_stale_book = nil
    if self._no_persist then
        -- Forked child: the parent persists the context from the outcome.
        return book
    end
    books[book_id] = book
    if before then
        local changed = false
        for _i, field in ipairs(CONTEXT_FIELDS) do
            if before[field] ~= book[field] then
                changed = true
                break
            end
        end
        if not changed then
            return book
        end
    end
    -- P0-1C: single-record write instead of rewriting every book's JSONs.
    self.settings:set_book(book_id, book)
    self:_schedule_context_flush()
    return book
end

local function apply_position(book, position)
    if type(position) ~= "table" then return book end
    book.chapter_uid = position.chapter_uid or book.chapter_uid
    book.chapter_idx = tonumber(position.chapter_idx) or tonumber(book.chapter_idx) or 0
    book.chapter_offset = tonumber(position.chapter_offset)
        or tonumber(book.chapter_offset) or 0
    book.progress = tonumber(position.percent or position.progress)
        or tonumber(book.progress) or 0
    book.summary = position.summary or book.summary or ""
    return book
end

function ReadReport:build_payload(book_id, elapsed_seconds, book, position)
    book = book or self:ensure_context(book_id, false)
    apply_position(book, position)
    return WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = book.chapter_uid,
        chapter_idx = tonumber(book.chapter_idx) or 0,
        chapter_offset = tonumber(book.chapter_offset) or 0,
        progress = tonumber(book.progress) or 0,
        summary = book.summary or "",
        elapsed_seconds = elapsed_seconds,
        app_id = book.app_id or WeRead.web_app_id(),
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
    }
end

function ReadReport:_send(book_id, book, position, elapsed_seconds)
    apply_position(book, position)
    if book.pclts == nil or book.pclts == "" or tonumber(book.pclts) == 0 then
        book.pclts = WeRead.e(self.now())
    end
    if book.read_session_id ~= self.session_id then
        book.read_session_id = self.session_id
        book.read_session_entered_at = nil
    end
    if not book.read_session_entered_at then
        local enter_payload = WeRead.make_enter_read_payload{
            book_id = book_id,
            chapter_uid = book.chapter_uid,
            chapter_idx = tonumber(book.chapter_idx) or 0,
            chapter_offset = tonumber(book.chapter_offset) or 0,
            progress = tonumber(book.progress) or 0,
            summary = book.summary or "",
            app_id = book.app_id or WeRead.web_app_id(),
            psvts = book.psvts,
            pclts = book.pclts,
        }
        self.client:report_read(
            enter_payload,
            book.reader_url or WeRead.reader_url(book_id),
            self:_request_opts()
        )
        book.read_session_entered_at = self.now()
        book.read_session_id = self.session_id
    end
    local payload = self:build_payload(
        book_id,
        elapsed_seconds == nil and self:_interval() or elapsed_seconds,
        book,
        position
    )
    -- P0-3a: pass the degraded timeout (nil on healthy links = client 8s).
    return self.client:report_read(payload,
        book.reader_url or WeRead.reader_url(book_id),
        self:_request_opts())
end

-- P0-3a helper: request options carrying the degraded timeout when the
-- report pipeline is in a failure streak.
function ReadReport:_request_opts()
    local timeout = self:_request_timeout()
    if timeout then
        return { timeout = timeout }
    end
    return nil
end

-- Async upload: spawns subprocess, calls on_complete(accepted, outcome) when done.
-- Returns (true, "async") if spawned, (false, outcome) if inline fallback.
function ReadReport:upload_position_async(book_id, position, elapsed_seconds, on_complete)
    if self.job then
        return false, { error = "read_report_busy", error_kind = "busy" }
    end
    local runner = self.subprocess
    if runner and self:_can_spawn() then
        local upload_book_id = tostring(book_id)
        local allow_renewal = self:_renewal_allowed()
        local elapsed = elapsed_seconds or 0
        local spawned, spawn_err = self:_start_job(upload_book_id, allow_renewal,
            self.generation, nil, position, elapsed, on_complete)
        if spawned then
            return true, "async"
        end
        log("warn", "upload_position_async spawn failed, running inline:",
            tostring(spawn_err))
    end
    -- Inline fallback: run synchronously and call on_complete
    local outcome = self:_run_pipeline(tostring(book_id), {
        allow_renewal = self:_renewal_allowed(),
        position = position,
        elapsed_seconds = elapsed_seconds or 0,
    })
    if outcome.renew_attempted then
        self.last_renew_attempt = self.now()
    end
    if type(outcome.book) == "table" then
        pcall(function() self:_persist_context(tostring(book_id), outcome.book) end)
    end
    if type(on_complete) == "function" then
        pcall(on_complete, outcome.accepted == true, outcome)
    end
    return outcome.accepted == true, outcome
end

-- Check whether subprocess spawning is available (P1-B helper).
function ReadReport:_can_spawn()
    return self.subprocess ~= nil and type(self.subprocess.run) == "function"
end

return ReadReport
