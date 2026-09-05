-- Unit tests for weread/lib/settings.lua with KOReader's LuaSettings /
-- DataStorage / lfs / BookStore replaced by in-memory stubs. Focus: the
-- books-cache contract (S-02), mutate_book/remove_book, the sync-defaults
-- backfill (S-18) and the corrupted-config type guard (P2-A).
package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return "/tmp/weread-test/data" end,
        getSettingsDir = function() return "/tmp/weread-test/settings" end,
    }
end

-- In-memory stand-in for KOReader's LuaSettings. Store contents can be
-- pre-seeded through the global __TEST_STORES table keyed by file path.
package.preload["luasettings"] = function()
    local LuaSettings = {}
    LuaSettings.__index = LuaSettings

    function LuaSettings:open(path)
        local data = (_G.__TEST_STORES or {})[path] or {}
        return setmetatable({ data = data, _path = path }, LuaSettings)
    end

    function LuaSettings:readSetting(key, default)
        local value = self.data[key]
        if value == nil then return default end
        return value
    end

    function LuaSettings:saveSetting(key, value)
        self.data[key] = value
    end

    function LuaSettings:delSetting(key)
        self.data[key] = nil
    end

    function LuaSettings:flush() end

    return LuaSettings
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        mkdir = function() return true end,
    }
end

-- BookStore stub: save records to an in-memory "disk" keyed by book id and
-- load them back (mirroring the real metadata/reading_state round-trip).
-- The disk resets on every Settings:new() via fresh_settings().
package.preload["weread.lib.book_store"] = function()
    local BookStore = {}
    function BookStore.load(_settings, book_id, index)
        local book = {}
        local saved = (_G.__TEST_DISK or {})[tostring(book_id)]
        if type(saved) == "table" then
            for key, value in pairs(saved) do book[key] = value end
        end
        if type(index) == "table" then
            for key, value in pairs(index) do book[key] = value end
        end
        book.book_id = book.book_id or tostring(book_id)
        book.cache_dir = book.cache_dir or ("cachedir-" .. tostring(book_id))
        return book
    end

    function BookStore.save(_settings, book_id, book)
        _G.__TEST_DISK = _G.__TEST_DISK or {}
        _G.__TEST_DISK[tostring(book_id)] = book
        return true, { cache_dir = "cachedir-" .. tostring(book_id) }
    end

    function BookStore.is_minimal_index(books)
        for _book_id, record in pairs(books or {}) do
            if type(record) ~= "table" then return false end
            for key in pairs(record) do
                if key ~= "cache_dir" then return false end
            end
        end
        return true
    end

    return BookStore
end

package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end

local function fresh_settings(store_seed)
    _G.__TEST_STORES = { ["/tmp/weread-test/settings/weread.lua"] = store_seed or {} }
    _G.__TEST_DISK = {}
    local Settings = require("weread.lib.settings")
    -- require is cached; Settings:new() reads the (re-seeded) store each time.
    return Settings:new()
end

describe("Settings get(\"books\") cache contract (S-02 / H-8)", function()
    it("hands out the same shared table on repeated gets", function()
        local settings = fresh_settings()
        local first = settings:get("books", {})
        local second = settings:get("books", {})
        assert.is_true(first == second)
    end)

    it("rebuilds the cache after set(\"books\") invalidates it", function()
        local settings = fresh_settings()
        local before = settings:get("books", {})
        settings:set("books", { B1 = { title = "one" } })
        local after = settings:get("books", {})
        assert.is_false(before == after)
        assert.equals("one", after.B1.title)
    end)
end)

describe("Settings:mutate_book (S-02)", function()
    it("applies the change, persists it and updates the cache", function()
        local settings = fresh_settings()
        settings:set("books", { B1 = { title = "old" } })
        local ok = settings:mutate_book("B1", function(book)
            book.title = "new"
        end)
        assert.is_true(ok)
        assert.equals("new", settings:get("books", {}).B1.title)
        local index = settings.store:readSetting("books")
        assert.is_not_nil(index.B1)
    end)

    it("returns false for unknown books and invalid arguments", function()
        local settings = fresh_settings()
        assert.is_false(settings:mutate_book("missing", function() end))
        assert.is_false(settings:mutate_book("B1", nil))
        assert.is_false(settings:mutate_book("", function() end))
    end)
end)

describe("Settings:remove_book (S-20)", function()
    it("drops the record from the index and the cache", function()
        local settings = fresh_settings()
        settings:set("books", { B1 = { title = "one" }, B2 = { title = "two" } })
        local cached = settings:get("books", {})
        assert.is_not_nil(cached.B1)
        assert.is_true(settings:remove_book("B1"))
        assert.is_nil(settings:get("books", {}).B1)
        assert.is_not_nil(settings.store:readSetting("books").B2)
        assert.is_false(settings:remove_book("B1")) -- already gone
    end)
end)

describe("Sync defaults backfill (S-18)", function()
    it("flips missing keys for dual-device defaults on old configs", function()
        local settings = fresh_settings({
            sync = { pull_on_open = false },
        })
        -- Explicitly saved false is respected; only the missing key is filled.
        local sync = settings:get("sync", {})
        assert.equals(false, sync.pull_on_open)
        assert.equals(true, sync.upload_on_close)
        assert.equals(true, sync.ask_on_conflict)
    end)

    it("applies the new defaults when no sync config exists", function()
        local settings = fresh_settings()
        local sync = settings:get("sync", {})
        assert.equals(true, sync.pull_on_open)
        assert.equals(true, sync.upload_on_close)
    end)
end)

describe("Corrupted-config type guard (P2-A)", function()
    it("falls back to defaults when a table key holds a scalar", function()
        local settings = fresh_settings({
            read_report = "corrupted-by-power-loss",
        })
        local config = settings:get("read_report")
        assert.is_table(config)
        assert.equals(true, config.enabled)
    end)
end)
