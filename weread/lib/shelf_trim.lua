-- weread/lib/shelf_trim.lua
-- v9.2 (K4weread): shelf weight trim — chunked rendering + cache freshness.
--
-- Device data (2026-11-08, K4): a 10157-book shelf made the old full
-- item-table build (per-book filter + downloaded check + closure) the
-- dominant shelf cost, on top of a ~8s /shelf/sync and a ~20s SQLite
-- cacheShelf. The bookshelf now renders one chunk and appends further
-- chunks as the user pages past the loaded window (library.lua), and the
-- background sync is skipped while the cached shelf is young.
--
-- Pure module: no KOReader or device dependencies. take_chunk treats a
-- throwing matcher as a non-match so a bad predicate can never break the
-- shelf build.

local M = {}

-- Pages rendered per chunk (per-page size comes from the shelf menu).
M.CHUNK_PAGES = 3

-- Background /shelf/sync is skipped while the cached shelf is younger than
-- this (device-measured sync cost: ~8s TLS + ~20s SQLite write).
M.FRESH_SECONDS = 300

-- Settings key for the last successful shelf sync (unix seconds).
M.SETTINGS_KEY = "shelf_synced_at"

function M.chunk_size(per_page)
    return math.max(1, tonumber(per_page) or 1) * M.CHUNK_PAGES
end

-- Walk `sorted` from start_index collecting matches until the chunk is
-- full, then keep scanning until one more match (lookahead → has_more) or
-- the end. Returns matched, has_more, next_start:
--   has_more=true  → next_start is the index of the lookahead match (the
--                    next chunk starts there, so no book is skipped)
--   has_more=false → next_start is nil (exhausted)
function M.take_chunk(sorted, matcher, start_index, chunk_size)
    if type(sorted) ~= "table" then
        return {}, false, nil
    end
    if type(start_index) ~= "number" or start_index < 1 then
        start_index = 1
    end
    chunk_size = math.max(1, tonumber(chunk_size) or 1)

    local matched = {}
    local i = start_index
    while i <= #sorted do
        local ok, hit = pcall(matcher, sorted[i])
        if ok and hit then
            if #matched >= chunk_size then
                return matched, true, i
            end
            matched[#matched + 1] = sorted[i]
        end
        i = i + 1
    end
    return matched, false, nil
end

-- True when the cached shelf is young enough to skip a background sync.
-- Corrupted or missing timestamps degrade to stale (sync runs).
function M.is_fresh(settings, now)
    local ok, at = pcall(function()
        return settings:get(M.SETTINGS_KEY)
    end)
    if not ok or type(at) ~= "number" then
        return false
    end
    now = tonumber(now) or os.time()
    return (now - at) < M.FRESH_SECONDS
end

-- Best-effort record of a successful shelf sync (device write cost is one
-- settings flush; a failure just means the next open re-syncs).
function M.mark_synced(settings, now)
    pcall(function()
        settings:set(M.SETTINGS_KEY, tonumber(now) or os.time())
    end)
end

return M
