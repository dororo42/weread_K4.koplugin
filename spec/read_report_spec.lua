-- Unit tests for the pure scheduling/watermark logic in
-- weread/lib/read_report.lua. KOReader modules (ui/time, ffi/util) and the
-- heavy lib modules are stubbed via package.preload; only the state machine
-- (backoff, tick pacing, watermark re-attach, rollback guard, flush
-- unschedule) is exercised.
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

local ReadReport = require("weread.lib.read_report")

-- Builds a ReadReport wired to an in-memory scheduler + settings stub.
-- Returns the instance and a harness for inspecting/stepping state.
local function new_report(config_overrides)
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
    local config = {
        enabled = true,
        mode = "manual",
        book_id = "B1",
        interval_seconds = 30,
    }
    if config_overrides then
        for key, value in pairs(config_overrides) do config[key] = value end
    end
    local settings = {
        get = function(_self, key, default)
            if key == "read_report" then return config end
            return default
        end,
        set = function() end,
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
    return report, {
        scheduled = scheduled,
        config = config,
        set_now = function(value) now = value end,
        get_now = function() return now end,
    }
end

describe("ReadReport backoff pacing (R-C / S-12)", function()
    it("uses the normal interval when healthy", function()
        local report = new_report()
        assert.equals(30, report:_interval())
        assert.equals(30, report:_next_tick_delay())
    end)

    it("ramps 30s then 60s on the first failures (backoff cap 60s)", function()
        local report = new_report()
        report.consecutive_failures = 1
        assert.equals(30, report:_next_tick_delay())
        report.consecutive_failures = 2
        assert.equals(60, report:_next_tick_delay())
        report.consecutive_failures = 3
        assert.equals(60, report:_next_tick_delay())
    end)

    it("stretches to 120s once the failure streak is sustained (S-12)", function()
        local report = new_report()
        report.consecutive_failures = 4
        assert.equals(120, report:_next_tick_delay())
        report.consecutive_failures = 9
        assert.equals(120, report:_next_tick_delay())
    end)

    it("drains a backlog at heartbeat pace when healthy", function()
        local report, harness = new_report()
        report:start("test")
        report.watermark = harness.get_now() - 600 -- 10min unsent backlog
        assert.equals(30, report:_next_tick_delay()) -- BACKLOG_TICK_SECONDS
        report:stop("test")
    end)
end)

describe("ReadReport._next_report_seconds", function()
    it("caps a single report at the 30s heartbeat (risk-control red line)", function()
        local report, harness = new_report()
        report:start("test")
        report.watermark = harness.get_now() - 3600
        assert.equals(30, report:_next_report_seconds())
        report:stop("test")
    end)

    it("never reports a negative or over-long rt", function()
        local report, harness = new_report()
        report:start("test")
        report.watermark = harness.get_now() + 500 -- clock in the "future"
        local seconds = report:_next_report_seconds()
        assert.is_true(seconds >= 0 and seconds <= 30)
        report:stop("test")
    end)
end)

describe("ReadReport clock rollback guard (S-03)", function()
    it("trips only when the clock moved behind the watermark", function()
        local report, harness = new_report()
        report:start("test")
        assert.is_false(report:_clock_rolled_back())
        report.watermark = harness.get_now() + 10
        assert.is_true(report:_clock_rolled_back())
        report.watermark = harness.get_now() - 10
        assert.is_false(report:_clock_rolled_back())
        report.watermark = nil
        assert.is_false(report:_clock_rolled_back())
        report:stop("test")
    end)
end)

describe("ReadReport cross-session backlog (pending_backlog fix)", function()
    it("re-attaches pending offline reading time in front of now", function()
        local report, harness = new_report({
            watermarks = { B1 = { pending_backlog = 600 } },
        })
        report:start("test")
        assert.equals(harness.get_now() - 600, report.watermark)
        assert.equals(600, report.pending_backlog_seconds)
        report:stop("test")
    end)

    it("caps re-attached backlog at 3h (R-A risk-control line)", function()
        local report, harness = new_report({
            watermarks = { B1 = { pending_backlog = 24 * 3600 } },
        })
        report:start("test")
        assert.equals(harness.get_now() - 3 * 3600, report.watermark)
        assert.equals(3 * 3600, report.pending_backlog_seconds)
        report:stop("test")
    end)
end)

describe("ReadReport teardown (S-05)", function()
    it("unschedules the coalesced flush timers on stop()", function()
        local report, harness = new_report()
        report:start("test")
        report.watermark = harness.get_now() - 30
        local scheduled_before = #harness.scheduled
        report:_persist_watermark()
        assert.is_true(#harness.scheduled > scheduled_before) -- flush timer live
        local flush_fn = report._watermark_flush_fn
        assert.is_not_nil(flush_fn)
        report:stop("test")
        assert.is_nil(report._watermark_flush_fn)
        for _, item in ipairs(harness.scheduled) do
            assert.not_equal(flush_fn, item.fn) -- no flush timer left behind
        end
    end)
end)
