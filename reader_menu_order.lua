-- reader_menu_order.lua
-- Custom menu order configuration for KOReader (template).
--
-- IMPORTANT: KOReader only reads this file from its own settings directory.
-- A copy inside the plugin folder is NOT loaded. To enable it, copy this
-- file to the KOReader settings directory on the device:
--     koreader/settings/reader_menu_order.lua
-- (restart KOReader afterwards; the built-in default lives at
-- frontend/ui/elements/reader_menu_order.lua and is overridden by the
-- settings copy).
--
-- This template places WeRead at the top of the tools menu for quick
-- access on Kindle 4. NOTE: the menu id must be "weread" (the plugin's
-- registered menu key, see weread/ui/menu.lua addToMainMenu), NOT the
-- plugin folder name. The "KOMenu:disabled" key used by some older custom
-- files is NOT a supported key in current KOReader and has been removed.

local order = {
    -- tools: weread_K4 first, then frequently used tools
    tools = {
        "weread",
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

return order
