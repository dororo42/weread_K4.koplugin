-- Unit tests for the B1 local reading-time ledger (reMarkable official-client
-- borrow: account first, report second).
--
-- Covers: per-day booking, daily cap, cross-book aggregation, snapshot
-- read-only copy, coalesced flush scheduling, unschedule, the accepted-outcome
-- booking hook in ReadReport:_apply_outcome, and the stop()-time offline
-- session booking.
package.preload["weread.lib.content"] = function()
    return {}
end
package.preload["weread.lib.protocol"] = function()
    return {}
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end

-- busted runs all specs in one state; stub the logger for both this spec and
-- any earlier-cached modules, and drop cached copies of the modules under
-- test so they reload against the stubs.
package.preload["weread.lib.logger"] = function()
    local nillog = { info = function() end, warn = function() end, err = function() end }
    nillog.scoped = function() return { info = function() end, warn = function() end, err = function() end } end
    return nillog
end
package.loaded["weread.lib.logger"] = (function()
    local f = package.preload["weread.lib.logger"]
    return f and f() or nil
end)()
package.loaded["weread.lib.stats_ledger"] = nil
package.loaded["weread.lib.read_report"] = nil
package.loaded["weread.lib.content"] = {}
package.loaded["weread.lib.protocol"] = {}
package.loaded["weread.lib.i18n"] = { tr = function(text) return text end }
package.loaded["ffi/util"] = { template = function(text) return text end }

local StatsLedger = require("weread.lib.stats_ledger")

local function new_ledger(now_value)
    local scheduled = {}
    local scheduler = {
        scheduleIn = function(_self, delay, fn)
            table.insert(scheduled, { delay = delay, fn = fn })
        end,
        unschedule = function(_self, fn)
            for i, item in ipairs(scheduled) do
                if item.fn == fn then
                    table.remove(scheduled, i)
                    return
                end
            end
        end,
    }
    local flushed = 0
    local config = {}
    local settings = {
        get = function(_self, key)
            assert.equals("read_report", key)
            return config
        end,
        set = function(_self, key, value)
            assert.equals("read_report", key)
            config = value
        end,
        flush = function() flushed = flushed + 1 end,
    }
    local ledger = StatsLedger:new(settings, scheduler, now_value and function() return now_value end or os.time)
    return ledger, {
        scheduled = scheduled,
        config = config,
        flush_count = function() return flushed end,
    }
end

describe("StatsLedger booking (B1, reMarkable borrow)", function()
    it("books seconds into the UTC day bucket of the timestamp", function()
        local ledger = new_ledger()
        -- 2026-09-16 12:00 UTC
        local ts = os.time({ year = 2026, month = 9, day = 16, hour = 12 })
        local day_total = ledger:add("B1", 90, ts)
        assert.equals(90, day_total)
        local snap = ledger:snapshot()
        assert.equals(90, snap.B1["20260916"])
    end)

    it("accumulates within a day and caps the day at 24h", function()
        local ledger = new_ledger()
        local ts = os.time({ year = 2026, month = 9, day = 16, hour = 12 })
        ledger:add("B1", 30, ts)
        ledger:add("B1", 30, ts)
        assert.equals(60, ledger:total("B1"))
        -- oversized single booking is clamped to the day cap
        ledger:add("B1", 40 * 3600, ts)
        assert.equals(24 * 3600, ledger:total("B1"))
    end)

    it("ignores non-positive and missing book ids", function()
        local ledger = new_ledger()
        assert.is_nil(ledger:add("", 30))
        assert.is_nil(ledger:add("B1", 0))
        assert.is_nil(ledger:add("B1", -5))
        assert.equals(0, ledger:total_all())
    end)

    it("sums across books and across days", function()
        local ledger = new_ledger()
        local t1 = os.time({ year = 2026, month = 9, day = 16, hour = 12 })
        local t2 = os.time({ year = 2026, month = 9, day = 17, hour = 12 })
        ledger:add("B1", 100, t1)
        ledger:add("B1", 200, t2)
        ledger:add("B2", 50, t1)
        assert.equals(350, ledger:total_all())
        -- day-key window: the UTC bucket holding t1 ("20260916") holds the
        -- B1 100 and the B2 50 regardless of the device timezone
        assert.equals(150, ledger:total_between_keys("20260916", "20260916"))
        assert.equals(200, ledger:total_between_keys("20260917", "20260917"))
        assert.equals(350, ledger:total_between_keys("20260916", "20260917"))
        -- timestamp wrapper maps instants onto UTC day keys
        assert.equals(150, ledger:total_between(t1 - 3600, t1 + 3600))
    end)

    it("snapshot returns an independent copy", function()
        local ledger = new_ledger()
        local ts = os.time({ year = 2026, month = 9, day = 16, hour = 12 })
        ledger:add("B1", 10, ts)
        local snap = ledger:snapshot()
        snap.B1["20260916"] = 999
        assert.equals(10, ledger:total("B1"))
    end)

    it("schedules one coalesced flush per window and flush_now persists", function()
        local ledger, harness = new_ledger()
        local ts = os.time({ year = 2026, month = 9, day = 16, hour = 12 })
        ledger:add("B1", 10, ts)
        ledger:add("B1", 10, ts)
        -- one scheduled flush despite two bookings
        assert.equals(1, #harness.scheduled)
        assert.is_true(ledger._flush_pending)
        ledger:flush_now()
        assert.is_false(ledger._flush_pending)
        assert.equals(1, harness.flush_count())
        -- config round-trips through settings.set
        assert.equals(20, harness.config.ledgers.B1["20260916"])
    end)

    it("unschedule cancels the pending flush closure", function()
        local ledger, harness = new_ledger()
        ledger:add("B1", 10)
        assert.equals(1, #harness.scheduled)
        ledger:unschedule()
        assert.equals(0, #harness.scheduled)
        assert.is_false(ledger._flush_scheduled)
    end)

    it("persists ledgers inside the shared read_report config (B11-protected)", function()
        local ledger, harness = new_ledger()
        ledger:add("B1", 42)
        ledger:flush_now()
        -- the ledger lives under read_report.ledgers, so the atomic flush
        -- added in B11 protects it too
        assert.is_table(harness.config.ledgers)
        assert.equals(42, harness.config.ledgers.B1[next(harness.config.ledgers.B1)])
    end)
end)

-- --------------------------------------------------------------------
-- R-2 (2026-09-19, review): bounded day-key retention
-- --------------------------------------------------------------------

describe("StatsLedger pruning (R-2)", function()
    it("drops day keys older than the retention window on booking", function()
        -- arbitrary fixed instant (2026-09-19 UTC-ish); day keys derived from
        -- it so the assertions stay timezone-independent
        local now_ts = 1790000000
        local ledger, harness = new_ledger(now_ts)
        local old_ts = now_ts - 120 * 86400     -- far beyond 90d retention
        local recent_ts = now_ts - 86400
        local old_day = os.date("!%Y%m%d", old_ts)
        local recent_day = os.date("!%Y%m%d", recent_ts)
        -- booking into a beyond-retention day is pruned in the same add()
        ledger:add("B1", 100, old_ts)
        assert.is_nil(harness.config.ledgers.B1[old_day])
        -- recent bookings survive the prune
        ledger:add("B1", 50, recent_ts)
        assert.equals(50, harness.config.ledgers.B1[recent_day])
        assert.equals(50, ledger:total("B1"))
    end)

    it("prune(keep_days) honours an explicit window and leaves malformed keys alone", function()
        local now_ts = 1790000000
        local ledger, harness = new_ledger(now_ts)
        harness.config.ledgers = {
            B1 = { ["20200101"] = 5, ["20260701"] = 7, junk = 3, [42] = 9 },
        }
        -- "20200101" is far beyond 90 days before the fixed instant;
        -- "20260701" (~80 days) stays; malformed keys are not this
        -- module's call and remain untouched.
        local removed = ledger:prune()
        assert.equals(1, removed)
        assert.is_nil(harness.config.ledgers.B1["20200101"])
        assert.equals(7, harness.config.ledgers.B1["20260701"])
        assert.equals(3, harness.config.ledgers.B1.junk)
        assert.equals(9, harness.config.ledgers.B1[42])
    end)

    it("prunes at most once per UTC day key", function()
        local now_ts = 1790000000
        local ledger = new_ledger(now_ts)
        local ts = now_ts - 86400
        ledger:add("B1", 10, ts)
        local pruned_at = ledger._prune_day
        assert.equals(os.date("!%Y%m%d", ts), pruned_at)
        -- a second booking into the same day does not re-run the prune
        ledger:add("B1", 10, ts)
        assert.equals(pruned_at, ledger._prune_day)
        assert.equals(20, ledger:total("B1"))
    end)
end)

-- --------------------------------------------------------------------
-- ReadReport integration: booking on accepted outcome + offline session
-- --------------------------------------------------------------------

local ReadReport = require("weread.lib.read_report")

local function new_report()
    local scheduled = {}
    local scheduler = {
        scheduleIn = function(_self, delay, fn)
            table.insert(scheduled, { delay = delay, fn = fn })
        end,
        unschedule = function(_self, fn)
            for i, item in ipairs(scheduled) do
                if item.fn == fn then
                    table.remove(scheduled, i)
                    return
                end
            end
        end,
    }
    local now = 1000000
    local config = { enabled = true, mode = "manual", book_id = "B1", interval_seconds = 30 }
    local settings = {
        get = function(_self, key, default)
            if key == "read_report" then return config end
            return default
        end,
        set = function(_self, key, value)
            if key == "read_report" then config = value end
        end,
        flush = function() end,
        is_cookie_configured = function() return true end,
    }
    local report = ReadReport:new{
        settings = settings,
        client = {},
        scheduler = scheduler,
        get_document = function() return {} end,
        detect_book = function() return "B1" end,
        is_online = function() return true end,
        now = function() return now end,
    }
    report.current_book_id = "B1"
    return report, {
        scheduled = scheduled,
        config = config,
        set_now = function(v) now = v end,
        get_now = function() return now end,
    }
end

describe("B1 ReadReport ledger integration", function()
    it("books the accepted seconds on a successful outcome", function()
        local report, harness = new_report()
        report.watermark = harness.get_now()
        report.started_at = harness.get_now()
        report:_apply_outcome({
            accepted = true,
            reported_seconds = 30,
        })
        assert.equals(30, report.ledger:total("B1"))
    end)

    it("does not book anything on a failed outcome", function()
        local report, harness = new_report()
        report.watermark = harness.get_now()
        report.started_at = harness.get_now()
        report:_apply_outcome({
            accepted = false,
            error = "boom",
            error_kind = "transport",
        })
        assert.equals(0, report.ledger:total_all())
    end)

    it("books offline session seconds at stop() time", function()
        local report, harness = new_report()
        report.started_at = harness.get_now()
        report.watermark = harness.get_now()
        -- simulate 5 minutes of reading after start
        harness.set_now(harness.get_now() + 300)
        report.last_active_at = harness.get_now()
        report:stop("document_closed")
        assert.equals(300, report.ledger:total("B1"))
    end)

    it("caps the stop()-time session booking at 24h", function()
        local report, harness = new_report()
        report.started_at = harness.get_now()
        report.watermark = harness.get_now()
        harness.set_now(harness.get_now() + 40 * 3600)
        report.last_active_at = harness.get_now()
        report:stop("document_closed")
        assert.equals(24 * 3600, report.ledger:total("B1"))
    end)
end)
