-- Glue between the WeRead settings menu and KOReader's built-in ReaderFooter
-- "wifi_status" item (the small Wi-Fi connected/disconnected glyph in the
-- bottom status bar). Introduced by the 2026-09-11 feasibility study
-- ("Option B"): reuse the native item instead of shipping a custom widget or
-- patching KOReader.
--
-- The refresh bookkeeping in apply_to_footer mirrors ReaderFooter's own
-- settings-toggle callback (frontend/apps/reader/modules/readerfooter.lua,
-- v2026.07.1 getMinibarOption callback, L1117-1174), restricted to the
-- wifi_status option. Branch order and refresh semantics are kept identical
-- so the footer's margin/generator/mode state ends up exactly where the
-- native toggle would have left it.
--
-- Semantics note: the native icon reflects NetworkMgr:isWifiOn() (radio/link
-- state), not Internet reachability (NetworkMgr:isOnline() does a blocking
-- DNS lookup and must stay off the UI loop -- see ui/common.lua).
local logger = require("weread.lib.logger")

local M = {}

local function get_store()
    local store = _G.G_reader_settings
    if type(store) == "table" and type(store.readSetting) == "function" then
        return store
    end
    return nil
end

function M.deep_copy(tbl)
    local copy = {}
    for k, v in pairs(tbl) do
        copy[k] = type(v) == "table" and M.deep_copy(v) or v
    end
    return copy
end

-- Return the live ReaderFooter in a ReaderUI context, nil elsewhere
-- (FileManager has no view/footer; every use site must stay nil-safe).
function M.resolve_footer(ui)
    local view = type(ui) == "table" and ui.view or nil
    local footer = view and view.footer or nil
    if type(footer) == "table" and type(footer.settings) == "table"
            and type(footer.set_has_no_mode) == "function" then
        return footer
    end
    return nil
end

-- Current enabled state. Prefers the live footer settings table (ReaderUI);
-- falls back to the persisted global "footer" table (FileManager context).
function M.read_enabled(ui)
    local footer = M.resolve_footer(ui)
    if footer then
        return footer.settings.wifi_status == true
    end
    local store = get_store()
    if store then
        local fs = store:readSetting("footer")
        if type(fs) == "table" then
            return fs.wifi_status == true
        end
    end
    return false
end

-- Persist reader_footer_mode like the native toggle does (G_reader_settings
-- is the same live table KOReader flushes on exit; we also flush eagerly --
-- see flush_store).
function M.save_reader_footer_mode(mode)
    local store = get_store()
    if store and type(store.saveSetting) == "function" then
        store:saveSetting("reader_footer_mode", mode)
    end
end

-- Eager flush: the native toggle relies on KOReader flushing settings on
-- exit, but the plugin convention is to persist on every user action so a
-- power loss cannot revert it. Flush errors are non-fatal.
function M.flush_store()
    local store = get_store()
    if store and type(store.flush) == "function" then
        local ok, err = pcall(store.flush, store)
        if not ok then
            logger.warn("flush G_reader_settings failed:", tostring(err))
        end
    end
end

-- Apply wifi_status on a live footer and run the native refresh bookkeeping.
-- Returns true when the footer was touched.
function M.apply_to_footer(footer, enabled)
    if type(footer) ~= "table" or type(footer.settings) ~= "table" then
        return false
    end
    enabled = enabled == true
    footer.settings.wifi_status = enabled

    local should_signal = false
    local should_update = false
    local prev_has_no_mode = footer.has_no_mode
    local first_enabled_mode_num = footer:set_has_no_mode()

    if footer.has_no_mode then
        -- wifi_status was the last enabled item: collapse the footer the way
        -- the native toggle does (progress bar alone, zero-height text).
        if footer.footer_text then
            footer.footer_text.height = 0
        end
        should_signal = true
        if footer.textGeneratorMap and footer.textGeneratorMap.empty then
            footer.genFooterText = footer.textGeneratorMap.empty
        end
        if footer.mode_list then
            footer.mode = footer.mode_list.off
        end
    elseif prev_has_no_mode then
        -- first enabled item came back: restore a displayable mode
        if footer.settings.all_at_once then
            if footer.mode_list then
                footer.mode = footer.mode_list.page_progress
            end
            if footer.applyFooterMode then
                footer:applyFooterMode()
            end
            M.save_reader_footer_mode(footer.mode)
        else
            M.save_reader_footer_mode(first_enabled_mode_num)
        end
        should_signal = true
    end
    -- (reclaim_height is never touched here, so its native branch is omitted.)

    if footer.settings.all_at_once then
        should_update = footer:updateFooterTextGenerator()
    elseif (footer.mode_list and footer.mode_list.wifi_status == footer.mode
                and footer.settings.wifi_status == false)
            or (prev_has_no_mode ~= footer.has_no_mode) then
        -- current mode got disabled: redraw with other enabled modes
        if not footer.has_no_mode then
            footer.mode = first_enabled_mode_num
        else
            -- all modes off: fake an innocuous mode exactly like the native
            -- "Show progress bar" toggle does
            footer.mode = footer.settings.disable_progress_bar
                and (footer.mode_list and footer.mode_list.off)
                or (footer.mode_list and footer.mode_list.page_progress)
                or footer.mode
        end
        should_update = true
        if footer.applyFooterMode then
            footer:applyFooterMode()
        end
        M.save_reader_footer_mode(footer.mode)
    end

    if should_update or should_signal then
        footer:refreshFooter(should_update, should_signal)
    end
    if footer.rescheduleFooterAutoRefreshIfNeeded then
        footer:rescheduleFooterAutoRefreshIfNeeded()
    end
    M.flush_store()
    return true
end

-- Apply the setting when no live footer exists (FileManager context): write
-- the persisted global "footer" table so it takes effect the next time a
-- book opens. A ReaderUI kept alive in the background shares this exact
-- table (readSetting returns it live), so it picks the change up on re-entry.
-- Returns true when the store was updated.
function M.apply_to_store(store, enabled)
    if type(store) ~= "table" or type(store.readSetting) ~= "function" then
        return false
    end
    enabled = enabled == true
    local fs = store:readSetting("footer")
    if type(fs) ~= "table" then
        fs = nil
    end
    if fs == nil then
        -- Seed a COMPLETE table from KOReader's own public defaults
        -- (readerfooter.default_settings; the same entry point the
        -- onetime_migration uses). Writing a partial table here would
        -- silently nil-out every other status-bar item on next reader open.
        local ok, ReaderFooter = pcall(require, "apps/reader/modules/readerfooter")
        local defaults = (ok and type(ReaderFooter) == "table")
            and ReaderFooter.default_settings or nil
        if type(defaults) ~= "table" then
            logger.warn("footer defaults unavailable; footer setting not written")
            return false
        end
        fs = M.deep_copy(defaults)
    end
    fs.wifi_status = enabled
    if enabled then
        -- keep the same contract as apply_to_footer's enable path: make sure
        -- the icon is actually visible (all_at_once shows it persistently)
        fs.all_at_once = true
    end
    store:saveSetting("footer", fs)
    M.flush_store()
    return true
end

return M
