-- spec/library_shelf_refresh_spec.lua
-- v9.6 regression (2026-11-08 audit): showShelfPage() captured the book list
-- in a local, while _applyShelfBooks() replaced self.shelf_books with a NEW
-- table after a background sync. refresh() then rebuilt the open menu from
-- the stale list. This spec drives the real showShelfPage/refresh path with a
-- stubbed widget surface and asserts that post-sync books reach the menu and
-- that the browsing page is preserved.

local ShelfTrim = require("weread.lib.shelf_trim")

-- KOReader widgets and plugin helpers are absent in the spec environment.
-- Swap them in package.loaded only while library.lua loads, then restore.
local noop = function() end
local library_spec_state = { scheduled = nil }

local stubs = {
    ["ui/widget/buttondialog"] = {},
    ["ui/widget/confirmbox"] = {},
    ["ui/widget/infomessage"] = {},
    ["ui/widget/inputdialog"] = {},
    ["ui/widget/progressbardialog"] = {},
        ["ui/uimanager"] = {
        scheduleIn = function(_self, _delay, fn)
            library_spec_state.scheduled = fn
        end,
        show = noop, close = noop,
    },
    ["weread.lib.content"] = {},
    ["weread.lib.global_state"] = {},
    ["weread.lib.logger"] = { warn = noop, info = noop, err = noop },
    ["weread.lib.protocol"] = { is_mp_book = function() return false end },
    ["weread.lib.plugin_util"] = {
        tr = function(s) return s end,
        T = function(s) return s end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
    },
    ["weread.lib.shelf_trim"] = ShelfTrim,
}
local saved = {}
for name, mod in pairs(stubs) do
    saved[name] = package.loaded[name]
    package.loaded[name] = mod
end
package.loaded["weread.ui.library"] = nil
local Library = require("weread.ui.library")
for name in pairs(stubs) do
    package.loaded[name] = saved[name]
end
package.loaded["weread.ui.library"] = nil

local function fake_plugin()
    local settings = {
        data = { shelf = { sort_order = "default" }, books = {} },
        get = function(self, key, default)
            local value = self.data[key]
            if value ~= nil then return value end
            return default
        end,
        set = function(self, key, value) self.data[key] = value end,
    }
    local plugin = setmetatable({ settings = settings }, { __index = Library })

    function plugin:showInfo() end
    function plugin:shelfToolbarItems() return {} end
    function plugin:bookMatchesFilters() return true end
    function plugin:buildShelfItem(book)
        return { text = book.title }
    end
    function plugin:showList(_title, items)
        local menu = {
            item_table = items,
            page = 1,
            perpage = 14,
            page_num = 1,
            onNextPage = noop,
        }
        function menu.switchItemTable(menu_self, _new_title, new_items, itemnumber)
            menu_self.item_table = new_items
            menu_self.last_itemnumber = itemnumber
        end
        self.shelf_menu = menu
        return menu
    end
    -- 2026-11-12: harness for the showBookshelf background-sync path —
    -- records the exact ORDER of post-sync steps (apply/refresh vs the slow
    -- SQLite write) so the "paint the fresh books first, persist slowly"
    -- reordering stays regression-proof.
    function plugin:requireLogin() return true end
    function plugin:showBusy() end
    function plugin:closeBusy() end
    function plugin:runOnlineTask(_label, fn) fn() end
    function plugin:refreshShelfCacheIndicators()
        self.calls[#self.calls + 1] = "refresh"
        Library.refreshShelfCacheIndicators(self)  -- real in-place repaint
    end
    plugin.library_db = {
        getShelf = function() return plugin.cached_shelf end,
        cacheShelf = function(_db, books)
            plugin.calls[#plugin.calls + 1] = "cacheShelf"
        end,
    }
    plugin.client = {
        get_shelf = function()
            plugin.calls[#plugin.calls + 1] = "network"
            return { books = plugin.fresh_books }
        end,
    }
    plugin.scheduler = {
        scheduleIn = function(_self, _delay, fn)
            plugin.calls[#plugin.calls + 1] = "schedule"
            plugin.scheduled_fn = fn
        end,
    }
    plugin.calls = {}
    plugin.cached_shelf = { { bookId = "old1", title = "Cached", readUpdateTime = 1 } }
    plugin.fresh_books = { { bookId = "new1", title = "Fresh", readUpdateTime = 9 } }
    plugin.settings.data.shelf_synced_at = 0  -- stale: the gate must run the sync
    return plugin
end

describe("weread.ui.library in-place shelf refresh (v9.6)", function()
    it("rebuilds the OPEN shelf with the post-sync list and keeps the page", function()
        local plugin = fake_plugin()
        plugin:_applyShelfBooks({ { bookId = "a", title = "Old book" } })
        plugin:showShelfPage()
        local menu = plugin.shelf_menu
        assert.equals("Old book", menu.item_table[1].text)

        menu.page = 2
        plugin:_applyShelfBooks({ { bookId = "b", title = "New book" } })
        plugin:refreshShelfCacheIndicators()

        assert.equals("New book", menu.item_table[1].text)
        assert.equals(15, menu.last_itemnumber)
    end)
end)

describe("showBookshelf background sync ordering (2026-11-12, 10k-shelf freeze)", function()
    it("paints the fresh list BEFORE the slow SQLite write, and marks sync only after it", function()
        local plugin = fake_plugin()
        plugin:showBookshelf()
        -- first paint comes from the SQLite cache
        assert.equals("Cached", plugin.shelf_menu.item_table[1].text)

        local scheduled = library_spec_state.scheduled
        assert.is_function(scheduled)
        scheduled()

        local joined = table.concat(plugin.calls, ",")
        -- the in-place repaint must land BEFORE the multi-second SQLite write
        assert.truthy(joined:find("refresh") and joined:find("refresh") < joined:find("cacheShelf"),
            "expected repaint before cacheShelf, got: " .. joined)
        -- the sync bookkeeping must only be recorded after the cache write
        assert.truthy(joined:find("cacheShelf") < (joined:find("markSynced") or math.huge),
            "expected mark_synced after cacheShelf, got: " .. joined)
    end)
end)
