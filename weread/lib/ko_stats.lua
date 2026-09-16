-- weread/lib/ko_stats.lua — optional read-only bridge into KOReader's built-in
-- statistics plugin (P1, 2026-09-17, three-way ledger reconciliation).
--
-- The B1 ledger card compares the weread-side ledger (server metric) against
-- the server period total. When the gap keeps growing there are two very
-- different root causes, and this module lets the card tell them apart:
--   * KOReader statistics ≈ ledger total, server low  -> the report pipeline
--     is the problem (network / signature / risk control) -> B3 experiment.
--   * KOReader statistics ≈ server, ledger high       -> the device-side
--     engines disagree on what "reading" is -> investigate the plugin.
--
-- Design constraints (K4 hardware + robustness):
--   * OPTIONAL, never load-bearing: every dependency (ffi/sqlite3 binding,
--     datastorage, the db file, the query itself) is pcall-guarded; any
--     failure returns nil and the view simply hides the third row. This
--     mirrors the library_db/updater optional-dependency precedent.
--   * READ-ONLY: one SELECT, no schema writes, no PRAGMAs that mutate.
--   * RATE-LIMITED BY CALL SITE: called once per stats-page open (from
--     ReadStats.fetch), never from the reading loop or page-turn path.
--
-- Scope caveat (deliberate): statistics.db has no weread book_id, so the
-- query sums ALL books' total_read_time. That is the right granularity for
-- attribution ("did the device-side engine record anything at all"), not an
-- exact weread-only figure; the card caption says so.

local M = {}

-- logger is optional at load time so the module stays unit-testable outside
-- KOReader (busted has no weread.lib.logger on the path unless stubbed).
local ok_logger, logger_mod = pcall(require, "weread.lib.logger")
local logger = ok_logger and type(logger_mod) == "table"
    and type(logger_mod.scoped) == "function"
    and logger_mod.scoped("KoStats")
    or nil

local function warn(...)
    if logger and logger.warn then
        logger.warn(...)
    end
end

-- Resolve the SQLite opener. KOReader's statistics plugin itself opens the
-- db via ffi/sqlite3's SQ3.open(path); we use the identical entry point so
-- behavior matches the plugin that owns the file.
local function resolve_opener(deps)
    if type(deps.open_db) == "function" then
        return deps.open_db
    end
    local ok_sq3, SQ3 = pcall(require, "ffi/sqlite3")
    if not ok_sq3 or type(SQ3) ~= "table" or type(SQ3.open) ~= "function" then
        return nil
    end
    return SQ3.open
end

local function resolve_db_path(deps)
    if type(deps.db_path) == "string" then
        return deps.db_path
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or type(DataStorage) ~= "table"
        or type(DataStorage.getSettingsDir) ~= "function" then
        return nil
    end
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

-- Extract the SUM column out of a resultset("i") payload. Returns nil for
-- every "unusable" shape (no rows, NULL sum, non-numeric) so the caller can
-- treat them uniformly as "no device-side reference available".
local function extract_total(rows)
    if type(rows) ~= "table" then
        return nil
    end
    local first = rows[1]
    if type(first) ~= "table" then
        return nil
    end
    local value = tonumber(first[1])
    if value == nil or value < 0 then
        return nil
    end
    return math.floor(value)
end

-- Snapshot the device-metric lifetime reading total.
-- deps (all optional, for unit tests): open_db(path)->conn, db_path.
-- Returns { total = seconds } on success, nil whenever anything is missing
-- or fails (the caller treats nil as "hide the row").
function M.snapshot(deps)
    deps = type(deps) == "table" and deps or {}

    local open_db = resolve_opener(deps)
    if not open_db then
        return nil
    end
    local db_path = resolve_db_path(deps)
    if not db_path then
        return nil
    end

    local ok_db, conn = pcall(open_db, db_path)
    if not ok_db or type(conn) ~= "table" then
        warn("statistics db unavailable; the KOReader row stays hidden")
        return nil
    end

    local ok_q, rows = pcall(function()
        local stmt = conn:prepare("SELECT SUM(total_read_time) FROM book")
        local result = stmt:reset():resultset("i")
        stmt:close()
        return result
    end)
    pcall(function() conn:close() end)
    if not ok_q then
        warn("statistics query failed (db present but unreadable):",
            tostring(rows))
        return nil
    end

    -- resultset("i") returns (rows, count); we only need the rows payload.
    local total = extract_total(type(rows) == "table" and rows or nil)
    if total == nil then
        return nil
    end
    return { total = total }
end

return M
