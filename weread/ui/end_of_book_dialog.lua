-- weread/ui/end_of_book_dialog.lua — WeRead quick navigation dialog.
--
-- Pure presentation layer: given navigation options and callbacks, it builds a
-- ButtonDialog offering bookshelf / chapter-list / next-chapter navigation. It
-- is shown both at the end of a WeRead chapter and through KOReader's gesture
-- actions. It performs no network, settings, or book-store I/O; the controller
-- computes the options and supplies the callbacks.

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local I18n = require("weread.lib.i18n")

local function _(text)
    return I18n.tr(text)
end

local M = {}

-- Show the quick menu dialog. The title already carries the WeRead brand,
-- so the buttons use plain labels (书架 / 微信读书已缓存 / 书籍详情 / 章节目录 /
-- 阅读统计 / 搜索 / 立即同步进度 / 上报状态 / 关闭书籍).
--   opts.show_chapter_nav : boolean — show the "chapter list" button
--                           (true only for single-chapter files, not full books)
--   opts.show_cached      : boolean — show the "WeRead cached" button
--   opts.show_sync_progress : boolean — show the full-width progress sync row
--   opts.show_report_status : boolean — replace the final-row "Cancel" button
--                           with "Report status" (Back already cancels)
--   callbacks             : { on_bookshelf, on_cached, on_search, on_chapter_list,
--                             on_book_details, on_read_stats, on_sync_progress,
--                             on_report_status, on_close_book }
-- Returns the dialog widget instance.
function M.show(opts, callbacks, controller)
    opts = opts or {}
    callbacks = callbacks or {}
    controller = controller or {}

    local dialog

    -- Close the dialog first, then defer the action so the UI has a chance to
    -- repaint before a potentially blocking navigation (scheduleIn(0.1) keeps
    -- the event loop cooperative — see CLAUDE.md).
    local function dismiss_then(action)
        UIManager:close(dialog)
        if action then
            UIManager:scheduleIn(0.1, action)
        end
    end

    local buttons = {}

    -- Row 1: bookshelf / WeRead cached. Both are always available: the cached
    -- list is a local, offline view (no login or network needed).
    local top_row = {
        {
            text = _("Bookshelf"),
            callback = function() dismiss_then(callbacks.on_bookshelf) end,
        },
    }
    if opts.show_cached then
        table.insert(top_row, {
            text = _("WeRead cached"),
            callback = function() dismiss_then(callbacks.on_cached) end,
        })
    end
    table.insert(buttons, top_row)

    -- Row 2: book details / chapter list. The chapter list stays visible in the
    -- global quick menu; the controller reports when the current document lacks
    -- WeRead chapter context.
    local details_row = {
        {
            text = _("Book details"),
            callback = function() dismiss_then(callbacks.on_book_details) end,
        },
    }
    if opts.show_chapter_nav then
        table.insert(details_row, {
            text = _("Chapter list"),
            callback = function() dismiss_then(callbacks.on_chapter_list) end,
        })
    end
    table.insert(buttons, details_row)

    -- Row 3: reading statistics / search
    table.insert(buttons, {
        {
            text = _("Reading statistics"),
            callback = function() dismiss_then(callbacks.on_read_stats) end,
        },
        {
            text = _("Search"),
            callback = function() dismiss_then(callbacks.on_search) end,
        },
    })

    -- Penultimate row: one full-width action, only for a regular WeRead book.
    if opts.show_sync_progress then
        table.insert(buttons, {
            {
                text = _("Sync progress now"),
                callback = function() dismiss_then(callbacks.on_sync_progress) end,
            },
        })
    end

    -- Final row: report status / close book.
    -- "Cancel" is dropped: the Back key already dismisses the dialog. When the
    -- caller opts in (show_report_status), the slot is reused for "Report
    -- status" so the quick menu gives one-tap access to the read-report state.
    local final_row = {}
    if opts.show_report_status then
        table.insert(final_row, {
            text = _("Report status"),
            callback = function() dismiss_then(callbacks.on_report_status) end,
        })
    else
        table.insert(final_row, {
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        })
    end
    table.insert(final_row, {
        text = _("Close book"),
        callback = function() dismiss_then(callbacks.on_close_book) end,
    })
    table.insert(buttons, final_row)

    dialog = ButtonDialog:new{
        title = _("WeRead · Quick menu"),
        buttons = buttons,
    }

    UIManager:show(dialog)
    -- v5.0: tracked so openFile's close-all also dismisses it as a fallback.
    if controller and controller.trackDialog then
        pcall(function() controller:trackDialog(dialog) end)
    end
    return dialog
end

return M
