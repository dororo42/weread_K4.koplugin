-- Unit tests for PositionMapper percent baselines (2026-10-05 audit F-17).
--
-- The local percent used to be floored (systematically ≤1 point low) while
-- the remote value is a float, so compare() saw a one-directional bias and
-- could judge "remote_ahead" at the threshold boundary even when the two
-- positions agree — walking the reading position backwards one pull at a
-- time. The fix rounds the local percent and compares both sides on a
-- shared 0.1-point baseline.
local PM = require("weread.lib.position_mapper")

local CHAPTERS = {
    { chapterUid = "u1", chapterIdx = 1, wordCount = 10000 },
}

describe("PositionMapper local percent rounding (F-17)", function()
    it("rounds the local percent instead of flooring it", function()
        -- 0.2199 * 100 = 21.9 → floor said 21, round says 22
        local position = PM.local_to_remote(CHAPTERS, 0.2199, { is_full_book = true })
        assert.equals(22, position.percent)
    end)

    it("keeps the exact fraction alongside the rounded percent", function()
        local position = PM.local_to_remote(CHAPTERS, 0.2199, { is_full_book = true })
        assert.equals(0.2199, position.fraction)
    end)
end)

describe("PositionMapper.compare shared baseline (F-17)", function()
    it("judges same when the float remote sits within the threshold of the rounded local", function()
        -- With the old floor the local side read 21 vs remote 23.99 →
        -- delta 2.99 → "remote_ahead" (a phantom regression); on the shared
        -- baseline the delta is 1.99 → same.
        local local_position = PM.local_to_remote(CHAPTERS, 0.2199, { is_full_book = true })
        assert.equals(22, local_position.percent)
        local comparison = PM.compare(local_position,
            { percent = 23.99, chapter_uid = "u1" }, 2)
        assert.equals("same", comparison)
    end)

    it("still detects a real remote lead past the threshold", function()
        local local_position = { percent = 22, chapter_uid = "u1" }
        local comparison = PM.compare(local_position,
            { percent = 30.4, chapter_uid = "u1" }, 2)
        assert.equals("remote_ahead", comparison)
    end)

    it("still detects a real local lead past the threshold", function()
        local local_position = { percent = 40, chapter_uid = "u1" }
        local comparison = PM.compare(local_position,
            { percent = 30.4, chapter_uid = "u1" }, 2)
        assert.equals("local_ahead", comparison)
    end)
end)

-- W-3 (2026-10-26 unified review v2, welite quality-audit #12 lesson): the
-- jump-target percent stays fractional. The old call site computed
-- floor(fraction*100+0.5); the half-point loss crosses page boundaries, so
-- "jump to page 29" reproducibly landed on page 28. main.lua's
-- goto_fraction now passes fraction_to_percent(fraction) straight through.
describe("PositionMapper.fraction_to_percent (W-3)", function()
    it("keeps the percent fractional", function()
        assert.is_true(math.abs(PM.fraction_to_percent(0.2949) - 29.49) < 1e-9)
        assert.is_true(math.abs(PM.fraction_to_percent(0.999) - 99.9) < 1e-9)
    end)

    it("no longer rounds to the nearest integer percent", function()
        -- the old integer pipeline would have produced 29 for this input
        assert.is_true(PM.fraction_to_percent(0.2949) > 29
            and PM.fraction_to_percent(0.2949) < 30)
    end)

    it("clamps out-of-range fractions", function()
        assert.equals(0, PM.fraction_to_percent(-0.5))
        assert.equals(100, PM.fraction_to_percent(1.5))
    end)

    it("treats garbage as zero", function()
        assert.equals(0, PM.fraction_to_percent(nil))
        assert.equals(0, PM.fraction_to_percent("not-a-number"))
    end)
end)
