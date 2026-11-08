-- spec/shelf_trim_spec.lua
-- v9.2 (K4weread): shelf weight trim — chunked rendering and cache
-- freshness for the bookshelf. Device data (2026-11-08): a 10157-book
-- shelf costs a full item-table build (filter + downloaded check + closure
-- per book) plus a ~8s sync and ~20s SQLite cacheShelf. This module holds
-- the pure decision logic; library.lua does the widget wiring.

local ShelfTrim = require("weread.lib.shelf_trim")

describe("weread.lib.shelf_trim", function()
    describe("chunk_size", function()
        it("scales pages per chunk", function()
            assert.equals(42, ShelfTrim.chunk_size(14))
        end)

        it("guards against absurd page sizes", function()
            assert.equals(ShelfTrim.CHUNK_PAGES, ShelfTrim.chunk_size(0))
            assert.equals(ShelfTrim.CHUNK_PAGES, ShelfTrim.chunk_size(-3))
        end)
    end)

    describe("take_chunk", function()
        local function range(n)
            local t = {}
            for i = 1, n do t[i] = i end
            return t
        end

        it("returns the first chunk of matches and the next start index", function()
            local matched, has_more, next_start =
                ShelfTrim.take_chunk(range(100), function(v) return true end, 1, 3)
            assert.same({ 1, 2, 3 }, matched)
            assert.is_true(has_more)
            assert.equals(4, next_start)
        end)

        it("continues from start_index (the lookahead match opens the next chunk)", function()
            local matched, has_more, next_start =
                ShelfTrim.take_chunk(range(100), function(v) return true end, 4, 3)
            assert.same({ 4, 5, 6 }, matched)
            assert.is_true(has_more)
            assert.equals(7, next_start)
        end)

        it("scans past non-matching entries and stops one match past the chunk", function()
            -- matches only even numbers: chunk of 2 needs a scan to 6 (lookahead)
            local matched, has_more, next_start =
                ShelfTrim.take_chunk(range(100), function(v) return v % 2 == 0 end, 1, 2)
            assert.same({ 2, 4 }, matched)
            assert.is_true(has_more)
            assert.equals(6, next_start)
        end)

        it("reports exhaustion when the tail holds no further match", function()
            local matched, has_more, next_start =
                ShelfTrim.take_chunk(range(3), function(v) return true end, 1, 10)
            assert.same({ 1, 2, 3 }, matched)
            assert.is_false(has_more)
            assert.is_nil(next_start)
        end)

        it("returns an empty exhausted result when nothing matches", function()
            local matched, has_more, next_start =
                ShelfTrim.take_chunk(range(5), function() return false end, 1, 3)
            assert.same({}, matched)
            assert.is_false(has_more)
            assert.is_nil(next_start)
        end)

        it("treats a throwing matcher as a non-match instead of failing", function()
            local matched, has_more =
                ShelfTrim.take_chunk(range(10), function(v)
                    if v == 3 then error("matcher surprise") end
                    return true
                end, 1, 2)
            assert.same({ 1, 2 }, matched)
            assert.is_true(has_more)
        end)

        it("normalizes out-of-range inputs", function()
            local matched, has_more = ShelfTrim.take_chunk(range(5), function() return true end, 0, 0)
            assert.same({ 1 }, matched)
            assert.is_true(has_more)
        end)
    end)

    describe("freshness", function()
        local saved_key

        before_each(function()
            saved_key = ShelfTrim.SETTINGS_KEY
        end)

        after_each(function()
            ShelfTrim.SETTINGS_KEY = saved_key
        end)

        local function fake_settings(state)
            return {
                get = function(_self, key) return state[key] end,
                set = function(_self, key, value) state[key] = value end,
            }
        end

        it("is stale when nothing was recorded", function()
            assert.is_false(ShelfTrim.is_fresh(fake_settings({}), 1000))
        end)

        it("is stale on corrupted (non-number) timestamps", function()
            assert.is_false(
                ShelfTrim.is_fresh(fake_settings({ [ShelfTrim.SETTINGS_KEY] = "garbage" }), 1000))
        end)

        it("is fresh inside the window and stale past it", function()
            local settings = fake_settings({ [ShelfTrim.SETTINGS_KEY] = 1000 })
            assert.is_true(ShelfTrim.is_fresh(settings, 1000 + ShelfTrim.FRESH_SECONDS - 1))
            assert.is_false(ShelfTrim.is_fresh(settings, 1000 + ShelfTrim.FRESH_SECONDS))
        end)

        it("mark_synced round-trips through settings", function()
            local state = {}
            local settings = fake_settings(state)
            ShelfTrim.mark_synced(settings, 12345)
            assert.equals(12345, state[ShelfTrim.SETTINGS_KEY])
            assert.is_true(ShelfTrim.is_fresh(settings, 12345 + ShelfTrim.FRESH_SECONDS - 1))
        end)
    end)
end)
