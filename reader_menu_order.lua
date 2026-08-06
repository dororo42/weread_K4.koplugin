-- reader_menu_order.lua
-- Custom menu order configuration for KOReader.
-- Places weread_K4 at the top of the tools menu for quick access on Kindle 4.
-- Hides touch-only and irrelevant plugins on non-touch devices.

local Device = require("device")

local order = {
    -- tools: weread_K4 first, then frequently used tools
    tools = {
        "weread_K4",
        "----------------------------",
        "read_timer",
        "calibre",
        "exporter",
        "statistics",
        "progress_sync",
        "cloudstorage",
        "move_to_archive",
        "wallabag",
        "news_downloader",
        "opds",
        "kosync",
        "text_editor",
        "profiles",
        "qrclipboard",
        "----------------------------",
        "more_tools",
    },

    -- more_tools: only keep useful items for Kindle 4 non-touch
    more_tools = {
        "auto_frontlight",
        "auto_warmth",
        "auto_dim",
        "auto_standby",
        "auto_suspend",
        "auto_turn",
        "battery_statistics",
        "book_shortcuts",
        "keep_alive",
        "synchronize_time",
        "doc_setting_tweak",
        "----------------------------",
        "plugin_management",
        "patch_management",
    },
}

-- Hide touch-only and irrelevant plugins on non-touch devices
if not Device:isTouchDevice() then
    order["KOMenu:disabled"] = {
        "gestures",
        "hotkeys",
        "perception_expander",
        "cover_browser",
        "cover_image",
        "external_keyboard",
        "japanese",
        "hello",
        "http_inspector",
        "terminal",
        "system_statistics",
        "vocabulary_builder",
        "archive_viewer",
        "SSH",
    }
end

return order
