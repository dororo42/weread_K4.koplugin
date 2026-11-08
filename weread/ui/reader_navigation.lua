-- End-of-book navigation dialog integration.
local EndOfBookDialog = require("weread.ui.end_of_book_dialog")
local PluginUtil = require("weread.lib.plugin_util")
-- v9.0 (K4weread): weread-only launch mode session state.
local OnlyMode = require("weread.lib.only_mode")
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")

local _ = PluginUtil.tr

local M = {}

-- K4 non-touch: give ScreenKB + Down (KOReader default: book map) to the WeRead
-- quick menu — but ONLY while a WeRead book is open.
--
-- Mechanism (KOReader v2026.07+; verified against source):
-- Modern KOReader moved physical-key bindings into the built-in
-- hotkeys.koplugin. Its defaults.lua maps modifier_plus_down (ScreenKB+Down)
-- to {book_map = true} in reader mode; the instance lives at self.ui.hotkeys
-- and receives the key via its own key_events ("ScreenKBPlusDown" ->
-- HotkeyAction, args "modifier_plus_down") -> onHotkeyAction(hotkey).
--
-- ReaderUI registers every plugin AFTER the core reader modules and
-- WidgetContainer:propagateEvent iterates children FORWARD (ipairs, first
-- registered wins). A plugin's plain onKeyPress therefore can never preempt
-- another plugin child (hotkeys) that registered earlier. The earlier comment
-- here claimed "reverse iteration, plugin runs first" — that was wrong, which
-- is why the original onKeyPress override never fired (book map kept opening).
--
-- Fix: wrap hotkeys:onHotkeyAction. When the hotkey is modifier_plus_down and
-- a WeRead book is open, run the quick menu; otherwise forward to the original
-- handler, which executes whatever the user bound that key to (default book
-- map; any Keyboard-shortcuts customization is respected too). All other
-- hotkeys pass through untouched.
function M:initHotkeyOverride()
    local hotkeys = self.ui and self.ui.hotkeys
    if not hotkeys or self._hotkeys_patched then return end
    local orig = hotkeys.onHotkeyAction
    if not orig then return end
    self._hotkeys_patched = true
    hotkeys.onHotkeyAction = function(hotkeys_self, hotkey)
        if hotkey == "modifier_plus_down" then
            local ok, result = xpcall(function()
                return self:detectWeReadBook()
            end, debug.traceback)
            if ok and result then
                return self:onShowWeReadQuickMenu()
            end
            if not ok then
                local logger = require("weread.lib.logger")
                logger.err("hotkey detectWeReadBook failed:", tostring(result))
            end
        end
        return orig(hotkeys_self, hotkey)
    end

    -- v9.0 (K4weread): in weread-only mode, Home opens the bookshelf instead
    -- of the file manager. Plain Home is not in hotkeys.koplugin's defaults
    -- (verified against KOReader v2026.07: ReaderUI registers key_events.Home
    -- itself — readerui.lua:551 — and onHome -> onClose + showFileManager,
    -- :929), so the interception point is a ReaderUI instance-method wrap,
    -- the same pattern as the hotkeys wrap above. The bookshelf opens over
    -- the reading view (document stays open, progress untouched); Back
    -- returns to the reading position. Guarded: without an onHome surface
    -- the stock behavior is kept.
    if OnlyMode.is_active() and type(self.ui.onHome) == "function" then
        local orig_home = self.ui.onHome
        self.ui.onHome = function(readerui_self, ...)
            local logger = require("weread.lib.logger")
            local ok, result = xpcall(function()
                return self:showBookshelf()
            end, debug.traceback)
            if not ok then
                logger.err("weread-only Home failed:", tostring(result))
                return orig_home(readerui_self, ...)
            end
            return result
        end
    end

    -- v9.3: weread-only Menu convergence — the Menu key opens the plugin's
    -- own menu tree (Bookshelf/Search/.../Settings) instead of KOReader's
    -- full top menu. ReaderMenu owns the Menu key: non-touch devices (K4)
    -- bind KeyPressShowMenu -> onKeyPressShowMenu, touch binds PressMenu ->
    -- onPressMenu (readermenu.lua:69-84, device v2026.07); wrap whichever
    -- exists. getMainMenuItems() builds live item tables (fresh callbacks
    -- each press), and the KOReader Menu widget renders sub_item_table
    -- nesting natively.
    if OnlyMode.is_active() and type(self.ui.menu) == "table" then
        local function wrap_menu_opener(field, orig_method)
            self.ui.menu[field] = function(menu_self, ...)
                local ok, shown = pcall(function()
                    return self:showWereadOnlyMenu()
                end)
                if ok and shown then
                    return true
                end
                if not ok then
                    local logger = require("weread.lib.logger")
                    logger.warn("weread-only menu failed:", tostring(shown))
                end
                return orig_method(menu_self, ...)
            end
        end
        if type(self.ui.menu.onKeyPressShowMenu) == "function" then
            wrap_menu_opener("onKeyPressShowMenu", self.ui.menu.onKeyPressShowMenu)
        end
        if type(self.ui.menu.onPressMenu) == "function" then
            wrap_menu_opener("onPressMenu", self.ui.menu.onPressMenu)
        end
    end

    -- v9.3: document close lands on the bookshelf instead of the file
    -- manager. ReaderUI:onClose is the common doc-close path (Back key);
    -- 0.2s later the bookshelf opens on the still-alive FileManager-side
    -- plugin instance (registerModule stores it as self[name] =
    -- ui_module — readerui.lua:94-99, device v2026.07). Two guards keep
    -- this honest: a live ReaderUI.instance means a NEW document took over
    -- (ScreenKB+Back previous-document switch — never pop the shelf over
    -- it), and a dead UIManager loop (menu exit → quit) means the
    -- scheduled callback simply never runs — no shelf after a real exit.
    if OnlyMode.is_active() and type(self.ui.onClose) == "function" then
        local orig_close = self.ui.onClose
        self.ui.onClose = function(readerui_self, ...)
            UIManager:scheduleIn(0.2, function()
                local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
                local fm = ok_fm and FileManager and FileManager.instance or nil
                local fm_plugin = fm and fm.weread_K4 or nil
                if not (fm_plugin and type(fm_plugin.showBookshelf) == "function") then
                    return
                end
                local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
                if ok_rui and ReaderUI and ReaderUI.instance then
                    return
                end
                local ok, err = xpcall(function()
                    return fm_plugin:showBookshelf()
                end, debug.traceback)
                if not ok then
                    local logger = require("weread.lib.logger")
                    logger.warn("weread-only post-close shelf failed:", tostring(err))
                end
            end)
            return orig_close(readerui_self, ...)
        end
    end
end

-- v9.3: the weread-only "necessary menu" — the plugin's own menu tree
-- rendered as a standalone list. Same item tables the KOReader top menu
-- shows under WeRead, so callbacks/enabled_func/submenus keep working;
-- KOReader chrome (other tools/tabs) stays out of the weread-only session.
function M:showWereadOnlyMenu()
    local items = self:getMainMenuItems()
    if type(items) ~= "table" or #items == 0 then
        return false
    end
    self:showList(_("WeRead"), items, _("No items."))
    return true
end

-- Dispatcher entry point used by KOReader gesture/profile actions. The quick
-- menu is a global WeRead entry point; actions that need a current WeRead book
-- explain why they are unavailable when invoked from another document.
function M:onShowWeReadQuickMenu()
    local ok, err = xpcall(function()
        return self:showEndOfBookDialog(self:detectWeReadBook())
    end, debug.traceback)
    if not ok then
        local logger = require("weread.lib.logger")
        logger.err("quick menu failed:", tostring(err))
        return nil
    end
    return true
end

-- Dispatcher entry point for a gesture that opens the WeRead bookshelf from
-- any document currently open in KOReader.
function M:onShowWeReadBookshelf()
    self:showBookshelf()
    return true
end

function M:showEndOfBookDialog(book_id)
    local file_path = self.ui.document and self.ui.document.file
    if not file_path then return false end

    local books = self.settings:get("books", {})
    local book = book_id and (books[tostring(book_id)] or books[book_id]) or nil
    local is_regular_weread_book = book ~= nil and not WeRead.is_mp_book(book_id)
    local chapters = is_regular_weread_book and self:ensureChaptersLoaded(book) or nil

    local function show_context_required()
        self:showTransientInfo(
            _("This action requires an open WeRead book."), 1)
    end

    EndOfBookDialog.show({
        show_chapter_nav = true,
        show_cached = true,
        show_sync_progress = true,
        show_report_status = true,
    }, {
        on_bookshelf = function()
            self:showBookshelf()
        end,
        on_cached = function()
            self:showCachedBooks()
        end,
        on_search = function()
            self:showSearch()
        end,
        on_chapter_list = function()
            if chapters then
                self:showChapterList(book)
            elseif is_regular_weread_book then
                -- v4.5 fix: the chapter list may be missing after a
                -- delete-and-redownload (record rebuilt without chapters).
                -- loadChapters recovers it from file cache -> SQLite ->
                -- online fetch instead of refusing.
                self:loadChapters(book, function(refreshed)
                    if type(refreshed) == "table" and #refreshed > 0 then
                        self:showChapterList(book)
                    else
                        show_context_required()
                    end
                end, false)
            else
                show_context_required()
            end
        end,
        on_book_details = function()
            if book then
                self:showCurrentBookDetails()
            else
                show_context_required()
            end
        end,
        on_read_stats = function()
            self:showReadStats()
        end,
        on_sync_progress = function()
            if is_regular_weread_book then
                self:onWeReadSyncProgress()
            else
                show_context_required()
            end
        end,
        on_report_status = function()
            self:showReportStatus()
        end,
        on_close_book = function()
            -- Mirror KOReader's ReaderStatus:openFileBrowser(): closing the
            -- reader alone exits the app when there is no file-manager stack, so
            -- reopen the file browser right after (positioned on the book file).
            local ui = self.ui
            if not ui then return end
            local file = ui.document and ui.document.file
            ui:onClose()
            if file and ui.showFileManager then
                ui:showFileManager(file)
            end
        end,
    }, self)
    return true
end

return M
