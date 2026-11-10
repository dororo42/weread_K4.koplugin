-- spec/reader_navigation_spec.lua
-- v9.7 audit: the converged weread-only menu gained a Reading style entry
-- (ShowConfigMenu, closing the standalone list first) and an Exit entry, but
-- shipped with zero specs. The wraps are also installed once per UI, not once
-- per plugin instance — ReaderUI rebuilds create new instances over the same
-- ui, so an instance-level guard nests the wraps (double 0.2s post-close
-- shelf callbacks). Both behaviours are pinned here with a stubbed widget
-- surface; no KOReader runtime is needed.
-- v9.10 (2026-11-10 K4 fix): the converged menu renders as a standalone
-- TouchMenu instead of the list Menu — sub_item_table_func entries (Settings,
-- report toggles) were un-navigable and checked_func had no checkbox there.
-- The tests pin the TouchMenu construction and the item ordering.

local recorded
local function reset()
    recorded = { closed = {}, events = {}, broadcasts = {}, touchmenus = {} }
end
reset()

local noop = function() end
local stubs = {
    ["device"] = { screen = { getWidth = function() return 600 end } },
    ["ui/event"] = { new = function(_, name) return { name = name } end },
    ["ui/uimanager"] = {
        scheduleIn = noop,
        show = noop,
        close = function(_, widget)
            recorded.closed[#recorded.closed + 1] = widget
        end,
        broadcastEvent = function(_, event)
            recorded.broadcasts[#recorded.broadcasts + 1] = event.name
        end,
    },
    ["ui/widget/touchmenu"] = {
        new = function(_, opts)
            local widget = { opts = opts }
            recorded.touchmenus[#recorded.touchmenus + 1] = widget
            return widget
        end,
    },
    ["weread.lib.plugin_util"] = { tr = function(s) return s end },
    ["weread.lib.only_mode"] = { is_active = function() return true end },
    ["weread.ui.end_of_book_dialog"] = {},
    ["weread.lib.protocol"] = {},
}
local saved = {}
for name, mod in pairs(stubs) do
    saved[name] = package.loaded[name]
    package.loaded[name] = mod
end
package.loaded["weread.ui.reader_navigation"] = nil
local Navigation = require("weread.ui.reader_navigation")
for name in pairs(stubs) do
    package.loaded[name] = saved[name]
end
package.loaded["weread.ui.reader_navigation"] = nil

local function fake_plugin()
    local ui = {
        handleEvent = function(_, event)
            recorded.events[#recorded.events + 1] = event.name
        end,
    }
    local plugin = setmetatable({ ui = ui }, { __index = Navigation })
    function plugin:getMainMenuItems()
        return {
            { text = "Bookshelf" },
            { text = "Search" },
            { text = "Settings" },
        }
    end
    function plugin:safeCallback(_label, fn) return fn end
    function plugin:trackDialog(_widget) end
    return plugin
end

describe("weread.ui.reader_navigation converged menu (v9.7)", function()
    before_each(reset)

    it("builds a TouchMenu with Reading style second, closing it before ShowConfigMenu", function()
        local plugin = fake_plugin()
        assert.is_true(plugin:showWereadOnlyMenu())
        assert.equals(1, #recorded.touchmenus)
        local menu = plugin._weread_only_menu
        assert.is_true(recorded.touchmenus[1] == menu)
        local opts = menu.opts
        assert.equals(600, opts.width)
        local tab = opts.tab_item_table[1]
        assert.equals("appbar.menu", tab.icon)
        assert.equals("Reading style", tab[2].text)

        tab[2].callback()
        assert.equals(1, #recorded.closed)
        assert.is_true(recorded.closed[1] == menu)
        assert.equals("ShowConfigMenu", recorded.events[1])
        assert.is_nil(plugin._weread_only_menu)
    end)

    it("appends Exit KOReader broadcasting the native Exit event", function()
        local plugin = fake_plugin()
        plugin:showWereadOnlyMenu()
        local menu = plugin._weread_only_menu
        local tab = menu.opts.tab_item_table[1]
        assert.equals("Exit KOReader", tab[#tab].text)
        tab[#tab].callback()
        assert.equals("Exit", recorded.broadcasts[1])
        assert.equals(1, #recorded.closed)
        assert.is_true(recorded.closed[1] == menu)
        assert.is_nil(plugin._weread_only_menu)
    end)
end)

describe("weread.ui.reader_navigation wrap idempotency", function()
    before_each(reset)

    it("installs the weread-only wraps once per ui", function()
        local ui = {
            hotkeys = { onHotkeyAction = function() return "orig" end },
            onHome = function() return "orig_home" end,
            menu = { onKeyPressShowMenu = function() return "orig_menu" end },
            onClose = function() return "orig_close" end,
        }
        local first = setmetatable({ ui = ui }, { __index = Navigation })
        first:initHotkeyOverride()
        local hotkeys_fn = ui.hotkeys.onHotkeyAction
        local menu_fn = ui.menu.onKeyPressShowMenu
        local home_fn = ui.onHome
        local close_fn = ui.onClose

        local second = setmetatable({ ui = ui }, { __index = Navigation })
        second:initHotkeyOverride()

        assert.is_true(ui.hotkeys.onHotkeyAction == hotkeys_fn)
        assert.is_true(ui.menu.onKeyPressShowMenu == menu_fn)
        assert.is_true(ui.onHome == home_fn)
        assert.is_true(ui.onClose == close_fn)
    end)
end)
