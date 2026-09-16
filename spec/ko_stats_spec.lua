-- spec/ko_stats_spec.lua — P1 three-way ledger reconciliation.
-- Covers the optional ko_stats bridge (dependency-injected, no real SQLite
-- under busted) and its wiring into ReadStats.fetch.

local KoStats = require("weread.lib.ko_stats")

-- Build a stub SQLite connection mirroring KOReader's ffi/sqlite3 surface:
-- conn:prepare(sql) -> stmt; stmt:reset() -> stmt; stmt:resultset("i") -> rows;
-- conn:close() recorded. Dot-syntax functions with explicit params keep
-- luacheck quiet about implicit-self shadowing in nested stubs.
local function new_stub_conn(rows, opts)
    opts = opts or {}
    local state = { closed = 0, prepared_sql = nil }
    local conn
    conn = {
        prepare = function(_c, sql)
            state.prepared_sql = sql
            if opts.prepare_error then
                error(opts.prepare_error)
            end
            local stmt = {}
            stmt.reset = function(s) return s end
            stmt.close = function() end
            stmt.resultset = function(_s, _mode)
                if opts.result_error then
                    error(opts.result_error)
                end
                return rows
            end
            return stmt
        end,
        close = function()
            state.closed = state.closed + 1
        end,
    }
    return conn, state
end

describe("ko_stats.snapshot (module)", function()
    it("returns nil when no opener can be resolved (outside KOReader)", function()
        -- No injected deps: ffi/sqlite3 is absent under busted, so the
        -- optional-dependency contract says "hide the row", never error.
        assert.is_nil(KoStats.snapshot())
        assert.is_nil(KoStats.snapshot({}))
    end)

    it("returns nil when the database cannot be opened", function()
        local snap = KoStats.snapshot({
            open_db = function() error("cannot open") end,
            db_path = "/tmp/statistics.sqlite3",
        })
        assert.is_nil(snap)
    end)

    it("returns nil and still closes the connection when the query fails", function()
        local conn, state = new_stub_conn(nil, { prepare_error = "no such table: book" })
        local opened
        local snap = KoStats.snapshot({
            open_db = function(path)
                opened = path
                return conn
            end,
            db_path = "/tmp/statistics.sqlite3",
        })
        assert.is_nil(snap)
        assert.equals("/tmp/statistics.sqlite3", opened)
        assert.equals(1, state.closed)
    end)

    it("sums total_read_time across books on the happy path", function()
        local conn, state = new_stub_conn({ { 7500 }, }, {})
        local snap = KoStats.snapshot({
            open_db = function() return conn end,
            db_path = "/tmp/statistics.sqlite3",
        })
        assert.is_table(snap)
        assert.equals(7500, snap.total)
        -- read-only contract: exactly one close, after the query.
        assert.equals(1, state.closed)
    end)

    it("returns nil when the sum is NULL (statistics db never populated)", function()
        local conn = new_stub_conn({}, {})
        assert.is_nil(KoStats.snapshot({
            open_db = function() return conn end,
            db_path = "/tmp/statistics.sqlite3",
        }))
    end)

    it("ignores non-numeric or negative sums defensively", function()
        local bad_text = new_stub_conn({ { "abc" } }, {})
        assert.is_nil(KoStats.snapshot({
            open_db = function() return bad_text end,
            db_path = "/tmp/statistics.sqlite3",
        }))
        local negative = new_stub_conn({ { -5 } }, {})
        assert.is_nil(KoStats.snapshot({
            open_db = function() return negative end,
            db_path = "/tmp/statistics.sqlite3",
        }))
    end)
end)

describe("ReadStats.fetch wiring for the ko probe", function()
    local preload_backup

    before_each(function()
        preload_backup = package.preload["weread.lib.ko_stats"]
        package.loaded["weread.lib.ko_stats"] = nil
        package.loaded["weread.lib.read_stats"] = nil
    end)

    after_each(function()
        package.preload["weread.lib.ko_stats"] = preload_backup
        package.loaded["weread.lib.ko_stats"] = nil
        package.loaded["weread.lib.read_stats"] = nil
    end)

    local function fetch_with(ko_snapshot)
        package.preload["weread.lib.ko_stats"] = function()
            return { snapshot = ko_snapshot }
        end
        local ReadStats = require("weread.lib.read_stats")
        local client = {
            get_read_stats = function(_client, _mode, _base_time)
                return { totalReadTime = 100 }
            end,
        }
        local ledger = { total_all = function() return 200 end }
        return ReadStats.fetch(client, "monthly", nil, ledger)
    end

    it("attaches ko_total to the ledger summary when the probe succeeds", function()
        local data = fetch_with(function() return { total = 7500 } end)
        assert.is_table(data.local_ledger)
        assert.equals(200, data.local_ledger.total)
        assert.equals(100, data.local_ledger.server_total)
        assert.equals(7500, data.local_ledger.ko_total)
    end)

    it("omits ko_total when the probe is unavailable (B1 layout intact)", function()
        local data = fetch_with(function() return nil end)
        assert.is_table(data.local_ledger)
        assert.equals(200, data.local_ledger.total)
        assert.is_nil(data.local_ledger.ko_total)
    end)

    it("omits ko_total when the probe itself errors (pcall containment)", function()
        local data = fetch_with(function() error("boom") end)
        assert.is_table(data.local_ledger)
        assert.is_nil(data.local_ledger.ko_total)
    end)
end)
