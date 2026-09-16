-- Main menu and settings menu composition.
local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("weread.lib.logger")
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")
local FooterIndicator = require("weread.ui.footer_indicator")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}

function M:onDispatcherRegisterActions()
    Dispatcher:registerAction("weread_sync_progress", {
        category = "none",
        event = "WeReadSyncProgress",
        title = _("WeRead · Sync reading progress"),
        reader = true,
    })
    Dispatcher:registerAction("weread_quick_menu", {
        category = "none",
        event = "ShowWeReadQuickMenu",
        title = _("WeRead · Quick menu"),
        reader = true,
    })
    Dispatcher:registerAction("weread_bookshelf", {
        category = "none",
        event = "ShowWeReadBookshelf",
        title = _("WeRead · Bookshelf"),
        reader = true,
    })
end

function M:addToMainMenu(menu_items)
    menu_items.weread = {
        text = _("WeRead"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
    }
end

function M:getMainMenuItems()
    -- High-frequency items first for key-navigation efficiency
    local items = {
        {
            text = _("Bookshelf"),
            callback = self:safeCallback(_("Bookshelf"), function()
                self:showBookshelf()
            end),
        },
        {
            text = _("Search"),
            callback = self:safeCallback(_("Search"), function()
                self:showSearch()
            end),
        },
        {
            text = _("Reading time report"),
            sub_item_table_func = function()
                if not self:requireLogin(true, true) then
                    return {}
                end
                return self:getReadReportMenuItems()
            end,
        },
        {
            text = _("Reading statistics"),
            callback = self:safeCallback(_("Reading statistics"), function()
                self:showReadStats()
            end),
        },
        {
            text = _("Settings"),
            sub_item_table_func = function()
                return self:getSettingsMenuItems()
            end,
        },
        -- Low-frequency items at the end
        {
            text_func = function()
                local account = self.settings:get("account", {})
                if (account.login_method == "qr" or account.login_method == "manual")
                    and tonumber(account.login_time or 0) > 0 then
                    local name = type(account.name) == "string" and account.name or ""
                    if name == "" then name = _("Unknown account") end
                    return T(_("Logged in · %1"), name)
                end
                return _("QR code login")
            end,
            keep_menu_open = true,
            callback = self:safeCallback(_("QR login"), function(touchmenu_instance)
                self._login_menu_instance = touchmenu_instance
                local account = self.settings:get("account", {})
                if (account.login_method == "qr" or account.login_method == "manual")
                    and tonumber(account.login_time or 0) > 0 then
                    self:showAccountStatus()
                else
                    self.qr_login:start()
                end
            end),
        },
        {
            text = T(_("About (v%1)"), self.version),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("WeRead Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with WeRead's user agreement and applicable laws and regulations.\n\nThis branch (K4 non-touch adaptation) is derived from official v0.6.0 and developed independently:\nhttps://github.com/dororo42/weread_K4.koplugin\n\nUpstream project (AGPL-3.0):\nhttps://github.com/finlater/weread.koplugin"), self.version),
                })
            end,
        },
    }

    -- Insert document-specific items after Bookshelf (position 2+)
    if self.ui.document then
        table.insert(items, 2, {
            text = _("Sync progress now"),
            enabled_func = function()
                local book_id = self:detectWeReadBook()
                return book_id ~= nil and not WeRead.is_mp_book(book_id)
            end,
            callback = self:safeCallback(_("Sync progress now"), function()
                self:onWeReadSyncProgress()
            end),
        })
        table.insert(items, 3, {
            text = _("Book details"),
            callback = self:safeCallback(_("Book details"), function()
                self:showCurrentBookDetails()
            end),
        })
    end

    return items
end

-- Toggle KOReader's built-in footer Wi-Fi status icon (feasibility study
-- 2026-09-11, Option B; v5.7 compact design). Reader context: applies to the
-- live footer via footer_indicator's native-mirroring bookkeeping. No live
-- footer (file manager): writes the global store; takes effect on next book
-- open. In the default single-item status bar the icon takes over the one
-- footer slot (progress bar unaffected); disabling restores page progress.
-- all_at_once is deliberately never touched: flipping it would crowd the
-- whole status bar on the 800px K4 screen.
function M:toggleFooterWifiIndicator(touchmenu_instance)
    local footer = FooterIndicator.resolve_footer(self.ui)
    if footer then
        local enabled = footer.settings.wifi_status ~= true
        local apply = self:safeCallback("footer wifi indicator", function()
            if FooterIndicator.apply_to_footer(footer, enabled) then
                logger.info("footer wifi indicator:", enabled and "enabled" or "disabled")
            end
        end)
        apply()
    else
        local enabled = FooterIndicator.read_enabled(self.ui)
        if FooterIndicator.apply_to_store(_G.G_reader_settings, not enabled) then
            UIManager:show(InfoMessage:new{
                text = _("Status bar setting saved. It takes effect the next time a book is opened."),
                timeout = 3,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Unable to update the status bar setting."),
                timeout = 3,
            })
        end
    end
    if touchmenu_instance then
        touchmenu_instance:updateItems()
    end
end

function M:getSettingsMenuItems()
    local items = {
        {
            text = _("Cache management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Scan and match local books"),
                        callback = self:safeCallback(_("Scan and match local books"), function()
                            self:confirmScanLocalCache()
                        end),
                    },
                    {
                        text = _("Cache cleanup"),
                        callback = self:safeCallback(_("Cache cleanup"), function()
                            self:showCacheManagement()
                        end),
                    },
                    {
                        text_func = function()
                            return T(_("Cache directory: %1"), BD.dirpath(self.settings:get_download_dir()))
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Cache directory"), function(touchmenu_instance)
                            self:showDownloadDirPicker(touchmenu_instance)
                        end),
                    },
                }
            end,
        },
        {
            text = _("Progress management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Pull progress on open"),
                        keep_menu_open = true,
                        check_callback_updates_menu = true,
                        checked_func = function()
                            return self.settings:get("sync").pull_on_open == true
                        end,
                        callback = self:safeCallback(_("Pull progress on open"),
                            function(touchmenu_instance)
                                local sync = self.settings:get("sync")
                                sync.pull_on_open = sync.pull_on_open ~= true
                                self.settings:set("sync", sync)
                                self.settings:flush()
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                            end),
                     },
                    {
                        text = _("Upload progress on close"),
                        keep_menu_open = true,
                        check_callback_updates_menu = true,
                        checked_func = function()
                            return self.settings:get("sync").upload_on_close == true
                        end,
                        callback = self:safeCallback(_("Upload progress on close"),
                            function(touchmenu_instance)
                                local sync = self.settings:get("sync")
                                sync.upload_on_close =
                                    sync.upload_on_close ~= true
                                self.settings:set("sync", sync)
                                self.settings:flush()
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                            end),
                    },
                }
            end,
        },
        {
            text = _("Download settings"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Footnote display position"),
                        sub_item_table_func = function()
                            local function current_mode()
                                return self.settings:get("cache").footnotes_mode
                                    == "page" and "page" or "chapter"
                            end
                            return {
                                {
                                    text = _("Chapter end"),
                                    keep_menu_open = true,
                                    check_callback_updates_menu = true,
                                    checked_func = function()
                                        return current_mode() == "chapter"
                                    end,
                                    callback = self:safeCallback(
                                        _("Chapter end"),
                                        function(touchmenu_instance)
                                            local cache = self.settings:get("cache")
                                            cache.footnotes_mode = "chapter"
                                            self.settings:set("cache", cache)
                                            self.settings:flush()
                                            if touchmenu_instance then
                                                touchmenu_instance:updateItems()
                                            end
                                        end),
                                },
                                {
                                    text = _("Page bottom + chapter end"),
                                    keep_menu_open = true,
                                    check_callback_updates_menu = true,
                                    checked_func = function()
                                        return current_mode() == "page"
                                    end,
                                    callback = self:safeCallback(
                                        _("Page bottom + chapter end"),
                                        function(touchmenu_instance)
                                            local cache = self.settings:get("cache")
                                            cache.footnotes_mode = "page"
                                            self.settings:set("cache", cache)
                                            self.settings:flush()
                                            if touchmenu_instance then
                                                touchmenu_instance:updateItems()
                                            end
                                        end),
                                },

                            }
                        end,
                    },
                    {
                        text = _("Book images"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings:get("cache").download_book_images
                        end,
                        -- M-4 fix: refresh the checkbox state immediately after
                        -- toggling. Without this the K4 user must back out and
                        -- re-enter the menu to see the new checkmark.
                        check_callback_updates_menu = true,
                        callback = self:safeCallback(_("Book images"), function(touchmenu_instance)
                            local cache = self.settings:get("cache")
                            cache.download_book_images = not cache.download_book_images
                            self.settings:set("cache", cache)
                            self.settings:flush()
                            logger.info(
                                "image download setting changed:",
                                "target=book",
                                "enabled=", tostring(cache.download_book_images)
                            )
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end),
                    },
                    {
                        text = _("Public account article images"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings:get("cache").download_mp_images
                        end,
                        check_callback_updates_menu = true,
                        callback = self:safeCallback(_("Public account article images"), function(touchmenu_instance)
                            local cache = self.settings:get("cache")
                            if cache.download_mp_images then
                                self:setMPImageDownload(false)
                                touchmenu_instance:updateItems()
                                return
                            end
                            UIManager:show(ConfirmBox:new{
                                text = _("Downloading public account article images may significantly increase download time. Continue?"),
                                ok_text = _("Confirm"),
                                ok_callback = self:safeCallback(_("Confirm"), function()
                                    self:setMPImageDownload(true)
                                    touchmenu_instance:updateItems()
                                end),
                                cancel_text = _("Cancel"),
                            })
                        end),
                    },
                    {
                        text = _("Chapter prefetch"),
                        sub_item_table_func = function()
                            return {
                                {
                                    text = _("Automatically prefetch next chapter"),
                                    keep_menu_open = true,
                                    check_callback_updates_menu = true,
                                    checked_func = function()
                                        return self.settings:get("cache").auto_prefetch_next_chapter
                                            == true
                                    end,
                                    callback = self:safeCallback(
                                        _("Automatically prefetch next chapter"),
                                        function(touchmenu_instance)
                                            local cache = self.settings:get("cache")
                                            local function apply(enabled)
                                                cache.auto_prefetch_next_chapter = enabled
                                                self.settings:set("cache", cache)
                                                self.settings:flush()
                                                if not enabled then
                                                    self.downloader:cancelPrefetch(
                                                        "setting_disabled")
                                                elseif self._current_weread_book_id then
                                                    local book_id = self._current_weread_book_id
                                                    UIManager:scheduleIn(0.1, function()
                                                        if self._current_weread_book_id == book_id then
                                                            self:maybePrefetchNextChapter(book_id)
                                                        end
                                                    end)
                                                end
                                                if touchmenu_instance then
                                                    touchmenu_instance:updateItems()
                                                end
                                            end

                                            if cache.auto_prefetch_next_chapter == true then
                                                apply(false)
                                                return
                                            end

                                            UIManager:show(ConfirmBox:new{
                                                text = _("Due to network conditions, automatic prefetching may cause a few seconds of delay when you start reading a new chapter. Enable it?"),
                                                ok_text = _("Confirm"),
                                                ok_callback = self:safeCallback(
                                                    _("Confirm"), function()
                                                        apply(true)
                                                    end),
                                                cancel_text = _("Cancel"),
                                            })
                                        end),
                                },
                                {
                                    text = _("Show prefetch notifications"),
                                    keep_menu_open = true,
                                    check_callback_updates_menu = true,
                                    enabled_func = function()
                                        return self.settings:get("cache").auto_prefetch_next_chapter
                                            == true
                                    end,
                                    checked_func = function()
                                        return self.settings:get("cache").show_prefetch_notifications
                                            ~= false
                                    end,
                                    callback = self:safeCallback(
                                        _("Show prefetch notifications"),
                                        function(touchmenu_instance)
                                            local cache = self.settings:get("cache")
                                            cache.show_prefetch_notifications =
                                                cache.show_prefetch_notifications == false
                                            self.settings:set("cache", cache)
                                            self.settings:flush()
                                            if touchmenu_instance then
                                                touchmenu_instance:updateItems()
                                            end
                                        end),
                                },
                            }
                        end,
                    },
                }
            end,
        },
    }

    table.insert(items, {
        text = _("Account management"),
        sub_item_table_func = function()
            return {
                {
                    text = _("Account status"),
                    callback = self:safeCallback(_("Account status"), function()
                        self:showAccountStatus()
                    end),
                },
                {
                    text = _("Manual login"),
                    sub_item_table_func = function()
                        return {
                            {
                                text = _("Configuration guide"),
                                keep_menu_open = true,
                                callback = self:safeCallback(_("Configuration guide"), function()
                                    self:showManualLoginGuide()
                                end),
                            },
                            {
                                text = _("Generate template"),
                                keep_menu_open = true,
                                callback = self:safeCallback(_("Generate template"), function()
                                    self:generateManualLoginTemplate()
                                end),
                            },
                            {
                                text = _("Import now"),
                                keep_menu_open = true,
                                callback = self:safeCallback(_("Import now"), function()
                                    self:importManualLogin()
                                end),
                            },
                        }
                    end,
                },
                {
                    text = _("Renew cookie now"),
                    keep_menu_open = true,
                    callback = self:safeCallback(_("Renew cookie now"), function()
                        self:renewCookieWithUI()
                    end),
                },
                {
                    text = _("Clear account data"),
                    keep_menu_open = true,
                    callback = self:safeCallback(_("Clear account data"), function()
                        self:confirmClearAccount()
                    end),
                },
            }
        end,
    })

    -- K4 v6.0 (user preference): the wifi footer toggle sits at rank 5 —
    -- after Account management — so the settings list leads with the
    -- read/download items for key-navigation efficiency. Labelled "wifi状态"
    -- via i18n.
    table.insert(items, {
        text = _("Network status icon in status bar"),
        help_text = _("Show a small Wi-Fi status icon in the reading status bar. In the default single-item bar the icon takes the one footer slot (progress bar unaffected); page numbers come back when it is disabled."),
        keep_menu_open = true,
        check_callback_updates_menu = true,
        checked_func = function()
            return FooterIndicator.read_enabled(self.ui)
        end,
        callback = self:safeCallback(_("Network status icon in status bar"),
            function(touchmenu_instance)
                self:toggleFooterWifiIndicator(touchmenu_instance)
            end),
    })

    return items
end

return M
