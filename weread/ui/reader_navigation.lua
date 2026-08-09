-- End-of-book navigation dialog integration.
local EndOfBookDialog = require("weread.ui.end_of_book_dialog")
local PluginUtil = require("weread.lib.plugin_util")
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
    })
    return true
end

return M
