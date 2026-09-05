-- Shared dialog, network-task, and account UI helpers.
local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("weread.lib.logger")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local PluginUtil = require("weread.lib.plugin_util")
local GlobalState = require("weread.lib.global_state")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local unpack_args = PluginUtil.unpack_args

local M = {}

function M:safeCallback(label, callback)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err("action failed:", label, log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end
end

function M:showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function M:showTransientInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

function M:showBusy(text)
    self:closeBusy()
    self.busy_message = InfoMessage:new{
        text = text,
        dismissable = false,
    }
    UIManager:show(self.busy_message)
    self:refreshUI()
end

function M:closeBusy()
    if self.busy_message then
        UIManager:close(self.busy_message)
        self.busy_message = nil
        self:refreshUI()
    end
end

function M:refreshUI()
    if UIManager.forceRePaint then
        local ok, err = pcall(function()
            UIManager:forceRePaint()
        end)
        if not ok then
            logger.warn("forceRePaint failed:", log_error(err))
        end
    end
end

function M:showInputDialog(dialog)
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        local ok, err = pcall(function()
            dialog:onShowKeyboard()
        end)
        if not ok then
            logger.warn("failed to show keyboard:", log_error(err))
        end
    end
end

function M:isNetworkOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isOnline then
        return true
    end
    local ok_online, online = pcall(function()
        return NetworkMgr:isOnline()
    end)
    if not ok_online then
        logger.warn("network status check failed:", log_error(online))
        return true
    end
    return online == true
end

-- Non-blocking connectivity check (interface link state only). Unlike
-- isNetworkOnline() it never resolves DNS, so it is safe on the UI loop.
function M:isNetworkConnected()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isConnected then
        return self:isNetworkOnline()
    end
    local ok_connected, connected = pcall(function()
        return NetworkMgr:isConnected()
    end)
    if not ok_connected then
        logger.warn("network link check failed:", log_error(connected))
        -- Return false (not true) so background tasks (ReadReport, ProgressSync)
        -- correctly detect offline when the link-state probe errors. UI flows
        -- that prefer "assume online and let the request fail" use
        -- isNetworkOnline() instead.
        return false
    end
    return connected == true
end

function M:showOffline(label)
    self:closeBusy()
    logger.warn("network unavailable:", label)
    self:showInfo(T(_("%1 failed:\n%2"), label, _("No network connection. Please connect Wi-Fi and try again.")))
end

function M:runOnlineTask(label, callback, delay)
    if not self:isNetworkOnline() then
        self:showOffline(label)
        return false
    end
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err("network task failed:", label, log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end)
    return true
end

function M:runNetworkAction(label, action)
    self:runOnlineTask(label, function()
        local ok, result = pcall(action)
        if ok then
            self:showInfo(result or label)
        else
            logger.err("network action failed:", label, log_error(result))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(result)))
        end
    end)
end

function M:showList(title, items, empty_text, options)
    if not items or #items == 0 then
        self:showInfo(empty_text or _("No items."))
        return
    end
    options = options or {}
    local menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
        items_per_page = options.items_per_page,
        subtitle = options.subtitle,
    }
    UIManager:show(menu)
    self:trackDialog(menu)
    return menu
end

-- v5.0: track every top-level widget the plugin shows, so a navigation can
-- close all of them at once. The stack lives in global_state because
-- openFile() may rebuild the ReaderUI (and this plugin instance) mid-flow;
-- state stored on the instance would be lost together with the stale
-- widgets. 原#2 收口 (2026-09-05): moved from a dedicated _G key into the
-- shared global_state slot.
local DIALOG_STACK_KEY = "dialog_stack"
-- S-21 (2026-09-05): widgets the user closes themselves stay in the stack
-- (only whole-stack teardown empties it); cap it so a long session cannot
-- grow it without bound. UIManager:close on an already-closed widget is
-- pcall-guarded below, so dropping the oldest entries is safe.
local MAX_TRACKED_DIALOGS = 16

function M:trackDialog(widget)
    if not widget then return end
    local stack = GlobalState.get(DIALOG_STACK_KEY)
    if type(stack) ~= "table" then
        stack = {}
        GlobalState.set(DIALOG_STACK_KEY, stack)
    end
    for _, existing in ipairs(stack) do
        if existing == widget then return end
    end
    while #stack >= MAX_TRACKED_DIALOGS do
        table.remove(stack, 1)
    end
    table.insert(stack, widget)
end

function M:closeTrackedDialogs()
    local stack = GlobalState.get(DIALOG_STACK_KEY)
    if type(stack) ~= "table" then return end
    GlobalState.clear(DIALOG_STACK_KEY)
    for i = #stack, 1, -1 do
        pcall(function()
            UIManager:close(stack[i])
        end)
    end
end

function M:requireLogin(require_cookie, require_api_key)
    local missing_cookie = require_cookie and not self.settings:is_cookie_configured()
    local missing_api_key = require_api_key and not self.settings:is_api_configured()
    if not missing_cookie and not missing_api_key then
        return true
    end
    self:showTransientInfo(_("Please scan the QR code to log in first."), 2)
    UIManager:scheduleIn(0.2, function()
        self.qr_login:start()
    end)
    return false
end

function M:refreshLoginMenu()
    local menu = self._login_menu_instance
    if menu and type(menu.updateItems) == "function" then
        local ok, err = pcall(function()
            menu:updateItems()
        end)
        if not ok then
            logger.warn("refresh login menu failed:", log_error(err))
        end
    end
    self:refreshUI()
end

function M:renewCookieWithUI()
    if not self:requireLogin(true, false) then
        return
    end
    self:runNetworkAction(_("Renew cookie"), function()
        self.client:renew_cookie()
        logger.info("cookie renewed")
        return _("WeRead cookie renewed.")
    end)
end

function M:showAccountStatus()
    local account = self.settings:get("account", {})
    local account_name = type(account.name) == "string" and account.name or ""
    if account_name == "" then
        account_name = (self.settings:is_cookie_configured() or self.settings:is_api_configured())
            and _("Unknown account") or _("Not logged in")
    end
    local login_method
    if account.login_method == "qr" then
        login_method = _("QR login")
    elseif account.login_method == "manual" then
        login_method = _("Manual login")
    else
        login_method = _("Unknown")
    end
    local cookie_status = self.settings:is_cookie_configured() and _("configured") or _("missing")
    local api_status = self.settings:is_api_configured() and _("configured") or _("missing")
    self:showInfo(T(
        _("Account: %1\nLogin method: %2\nCookie: %3\nOfficial API key: %4\nCache directory:\n%5"),
        account_name,
        login_method,
        cookie_status,
        api_status,
        BD.dirpath(self.settings.cache_dir)
    ))
end

function M:confirmClearAccount()
    UIManager:show(ConfirmBox:new{
        text = _("Clear WeRead cookie and API key? Cached books will remain."),
        ok_text = _("Clear"),
        ok_callback = self:safeCallback(_("Clear"), function()
            self.qr_login:cancel()
            self.read_report:stop("account_cleared")
            self.settings:reset_account()
            self:refreshLoginMenu()
            self:showInfo(_("WeRead account data cleared."))
        end),
    })
end

function M:showManualLoginGuide()
    local guide = _([[Manual login guide:

1. Select "Generate template" to create
   weread_manual_login.lua in settings dir

2. Connect Kindle via USB and edit:
   koreader/settings/weread_manual_login.lua

3. Fill in credentials (replace YOUR_xxx):
   api_key  — WeRead API Key
   wr_skey  — WeRead Cookie
   wr_vid   — WeRead user ID
   wr_rt    — Refresh token (optional)
   name     — Your nickname (optional)

4. How to get credentials:
   a. Open https://weread.qq.com in browser
      Login with WeChat QR
   b. Press F12
      Application → Cookies → weread.qq.com
   c. Copy wr_skey, wr_vid, wr_rt values
   d. API Key:
      WeRead App → Me → Settings
      → WeRead Skill → Get API Key

5. Save file and restart KOReader
   Plugin auto-imports and deletes template

6. Or select "Import now" (no restart needed)]])
    self:showInfo(guide)
end

function M:generateManualLoginTemplate()
    local ok, err = self.settings:generate_manual_login_template()
    if ok then
        self:showInfo(T(_("Template generated at:\n%1\n\nConnect via USB, edit the file,\nthen restart KOReader or use \"Import now\"."),
            self.settings:get_manual_login_path()))
    else
        logger.err("generate manual login template failed:", tostring(err))
        self:showInfo(T(_("Failed to generate template: %1"), tostring(err)))
    end
end

function M:importManualLogin()
    local ok, err = self.settings:import_manual_login()
    if ok then
        self:refreshLoginMenu()
        self:showInfo(_("Manual login imported successfully."))
    elseif err == "not_found" then
        self:showInfo(_("No manual login file found.\nGenerate a template first."))
    elseif err == "not_filled" then
        self:showInfo(_("Template not filled in.\nEdit the file and replace YOUR_xxx placeholders."))
    elseif err == "invalid_format" then
        self:showInfo(_("Manual login file has invalid format.\nPlease check the Lua syntax."))
    else
        self:showInfo(T(_("Import failed: %1"), tostring(err)))
    end
end

return M
