-- weread/lib/stats_ledger.lua — local per-day reading-time ledger (B1).
--
-- The official reMarkable client keeps a local reading-time account
-- (reading_progress.reading_time, written on book open AND on every accepted
-- report — "account first, report second"), so offline reading stays visible
-- and a silently-swallowed report becomes detectable by comparing the local
-- ledger against the server's /readdata/detail totals.
--
-- K4 stores the ledger as { [yyyymmdd] = seconds } per book, persisted through
-- the regular Settings store (read_report.ledgers[book_id]) with the same
-- coalesced flush the watermark already uses: no SQLite open/close per tick,
-- no schema, and the file is loss-guarded by B11's atomic flush.
--
-- Data sources, in order of preference:
--   1. accepted_seconds — increments the server explicitly accepted
--      (_apply_outcome: watermark advanced by outcome.reported_seconds). This
--      is the exact "server-accepted" notion the official client books.
--   2. session seconds — time spent reading between start()/stop() when the
--      report pipeline could not confirm acceptance (offline reading). Still
--      real reading time; booked so the ledger stays meaningful offline.
-- Both paths go through add(): idempotent per day, clamped to sane bounds.

local M = {}
M.__index = M

local MAX_DAY_SECONDS = 24 * 3600

function M:new(settings, scheduler, now)
    assert(settings, "stats ledger settings are required")
    return setmetatable({
        settings = settings,
        scheduler = scheduler,
        now = now or os.time,
        -- dirty flag + deferred flush, mirroring watermark/context flushing
        _flush_pending = false,
        _flush_scheduled = false,
        _flush_fn = nil,
    }, self)
end

local function day_key(ts)
    return tostring(os.date("!%Y%m%d", ts))
end
M.day_key = day_key

local function read_config(self)
    return self.settings:get("read_report") or {}
end

local function ledgers(self)
    local cfg = read_config(self)
    local table_ref = cfg.ledgers
    if type(table_ref) ~= "table" then
        table_ref = {}
        cfg.ledgers = table_ref
    end
    return table_ref
end

local function total_of(entry)
    local total = 0
    if type(entry) == "table" then
        for _day, seconds in pairs(entry) do
            total = total + (tonumber(seconds) or 0)
        end
    end
    return total
end
M.total_of = total_of

-- Book `seconds` of reading into the per-day bucket for book_id at ts.
-- Returns the new day total, or nil when the input is not bookable.
function M:add(book_id, seconds, ts)
    book_id = tostring(book_id or "")
    seconds = tonumber(seconds) or 0
    ts = ts or self.now()
    if book_id == "" or seconds <= 0 then
        return nil
    end
    if seconds > MAX_DAY_SECONDS then
        seconds = MAX_DAY_SECONDS
    end
    local table_ref = ledgers(self)
    local entry = table_ref[book_id]
    if type(entry) ~= "table" then
        entry = {}
        table_ref[book_id] = entry
    end
    local key = day_key(ts)
    local day_total = (tonumber(entry[key]) or 0) + seconds
    if day_total > MAX_DAY_SECONDS then
        day_total = MAX_DAY_SECONDS
    end
    entry[key] = day_total
    self:_schedule_flush()
    return day_total
end

-- Total seconds booked for one book (or nil when the book has no ledger).
function M:total(book_id)
    local entry = ledgers(self)[tostring(book_id or "")]
    if type(entry) ~= "table" then return nil end
    return total_of(entry)
end

-- Sum across all books (server-side totalReadTime comparison baseline).
function M:total_all()
    local table_ref = ledgers(self)
    local total = 0
    for _book_id, entry in pairs(table_ref) do
        total = total + total_of(entry)
    end
    return total
end

-- { book_id = { day = seconds, ... } } shallow copy for read-only consumers.
function M:snapshot()
    local table_ref = ledgers(self)
    local out = {}
    for book_id, entry in pairs(table_ref) do
        if type(entry) == "table" then
            local copy = {}
            for day, seconds in pairs(entry) do
                copy[day] = seconds
            end
            out[book_id] = copy
        end
    end
    return out
end

-- Sum of all books whose UTC day key falls in [from_key, to_key]
-- (inclusive "YYYYMMDD" strings). Day keys are UTC buckets; comparing them
-- numerically avoids the device-timezone reconstruction trap that
-- os.time({...}) would introduce (the bucket meaning must stay UTC).
function M:total_between_keys(from_key, to_key)
    from_key = tostring(from_key or "")
    to_key = tostring(to_key or math.huge)
    local table_ref = ledgers(self)
    local total = 0
    for _book_id, entry in pairs(table_ref) do
        if type(entry) == "table" then
            for day, seconds in pairs(entry) do
                if #day == 8 and day >= from_key and day <= to_key then
                    total = total + (tonumber(seconds) or 0)
                end
            end
        end
    end
    return total
end

-- Timestamp-flavored convenience wrapper: converts the instants to UTC day
-- keys (os.date("!%Y%m%d") is TZ-independent, unlike os.time round-trips).
function M:total_between(from_ts, to_ts)
    return self:total_between_keys(
        os.date("!%Y%m%d", from_ts),
        os.date("!%Y%m%d", to_ts))
end

-- Coalesced flush: same pattern as the watermark/context flushes (M-L9/S-05):
-- mark dirty, schedule one flush 30s out, keep the closure reachable so
-- stop() can unschedule it.
function M:_schedule_flush()
    self._flush_pending = true
    if not self.scheduler then
        self:flush_now()
        return
    end
    if not self._flush_scheduled then
        self._flush_scheduled = true
        self._flush_fn = function()
            self._flush_scheduled = false
            self._flush_fn = nil
            if self._flush_pending then
                self._flush_pending = false
                pcall(function() self:flush_now() end)
            end
        end
        self.scheduler:scheduleIn(30, self._flush_fn)
    end
end

function M:flush_now()
    self._flush_pending = false
    self.settings:set("read_report", read_config(self))
    self.settings:flush()
end

-- stop()-time cancel (call from ReadReport:stop alongside the other
-- unschedule calls); the forced flush in stop() persists the ledger anyway.
function M:unschedule()
    if self._flush_scheduled and self._flush_fn and self.scheduler then
        self.scheduler:unschedule(self._flush_fn)
    end
    self._flush_scheduled = false
    self._flush_fn = nil
end

return M
