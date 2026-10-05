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
