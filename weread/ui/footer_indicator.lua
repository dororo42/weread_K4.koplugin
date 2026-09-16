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
-- native toggle would have left it. Host methods are probed before use
-- (v5.7 hardening): a KOReader build without one of the expected hooks
-- degrades to a conservative fallback instead of erroring.
--
-- Semantics note: the native icon reflects NetworkMgr:isWifiOn() (radio/link
-- state), not Internet reachability (NetworkMgr:isOnline() does a blocking
-- DNS lookup and must stay off the UI loop -- see ui/common.lua).
local logger = require("weread.lib.logger")

-- MODE declaration order in readerfooter.lua v2026.07.1 (module-local there).
-- The persisted "reader_footer_mode" is a POSITION inside the footer's
-- mode_index (0-based; mode_index[0] = "off"), NOT the MODE constant value:
-- device-gated items are dropped before the index is built (readerfooter.lua
-- L557-569), so on a frontlight-less Kindle 4 wifi_status lands at position
-- 10 even though MODE.wifi_status == 11. Users who arranged status-bar items
-- ("Arrange items") get their saved "footer.order" layout instead. Both
-- shapes are mirrored by compute_mode_positions(); no constant can encode
-- this, so the position is always computed (v5.7 fix for the FM store path:
-- the previous hardcoded 11 pointed at "book_title" on K4, leaving the icon
-- invisible after an enable from the file manager).
local MODE_ORDER = {
    "off", "page_progress", "pages_left_book", "time", "pages_left",
    "battery", "percentage", "book_time_to_read", "chapter_time_to_read",
    "frontlight", "mem_usage", "wifi_status", "book_title", "book_chapter",
    "bookmark_count", "chapter_progress", "frontlight_warmth", "custom_text",
    "book_author", "page_turning_inverted", "dynamic_filler", "additional_content",
}

-- Device gates mirroring readerfooter.lua init (v2026.07.1 L557-569): the
-- item is removed from MODE when the device capability probe returns false.
local DEVICE_GATES = {
    wifi_status = "hasFastWifiStatusQuery",
    frontlight = "hasFrontlight",
    frontlight_warmth = "hasNaturalLight",
    battery = "hasBattery",
}

-- The plugin target is a frontlight-less Kindle; without a live device
-- abstraction (unit tests, exotic hosts) only the frontlight family is
-- assumed absent.
local DEFAULT_UNSUPPORTED = { frontlight = true, frontlight_warmth = true }

local M = {}

-- Probe a device capability the same way readerfooter gates its MODE table.
-- Outside KOReader (tests / exotic embeds) the K4-shaped assumption set is
-- used; inside KOReader a missing or erroring probe is treated as
-- UNSUPPORTED so the FM path never persists a mode position for an item the
-- native footer might not build.
function M.device_supports(capability)
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" then
        -- K4 fallback (no device module): compute_mode_positions passes
        -- CAPABILITY names (hasFrontlight etc.), but DEFAULT_UNSUPPORTED is
        -- keyed by MODE names; translate before the lookup, otherwise the
        -- frontlight family is misjudged as supported and never dropped
        -- (v5.7.1 CI fix: busted "falls back to the K4 shape" 11 != 10).
        local CAP_TO_MODE = { hasFrontlight = "frontlight", hasNaturalLight = "frontlight_warmth" }
        local mode = CAP_TO_MODE[capability] or capability
        local unsupported = DEFAULT_UNSUPPORTED[mode]
        return not unsupported
    end
    local probe = Device[capability]
    if type(probe) ~= "function" then
        return false
    end
    local ok_probe, supported = pcall(probe, Device)
    if not ok_probe then
        return false
    end
    return supported == true
end

-- Mirror readerfooter.lua's set_mode_index (v2026.07.1): a saved custom
-- order ("footer.order", index 0 = "off", written by the SortWidget) is used
-- verbatim for the items it lists; remaining known items follow in ascending
-- MODE order. Device-gated items are dropped in both paths. Returns a
-- name -> 0-based position map.
function M.compute_mode_positions(footer_settings)
    local order = type(footer_settings) == "table"
        and type(footer_settings.order) == "table"
        and footer_settings.order or nil

    local positions = {}
    local count = 0
    -- A name absent from MODE_ORDER (e.g. a future KOReader footer mode our
    -- static mirror has not caught up with) is still placed when it appears in
    -- a saved custom order: such names carry no device gate, so they are always
    -- included. This keeps the persisted reader_footer_mode self-consistent
    -- instead of silently dropping the item under KOReader MODE reordering
    -- (v5.7.x robustness fallback, audit item 3).
    local function add(name)
        if type(name) ~= "string" or positions[name] ~= nil then
            return
        end
        local gate = DEVICE_GATES[name]
        if gate and not M.device_supports(gate) then
            return
        end
        positions[name] = count
        count = count + 1
    end

    if order then
        -- #order is used exactly like the official loop (the table is
        -- 0-based; both run in the same Lua, so # behaves identically).
        for i = 0, #order do
            local name = order[i]
            if type(name) == "string" then
                add(name)
            end
        end
    end
    for _, name in ipairs(MODE_ORDER) do
        add(name)
    end
    return positions
end

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

-- Backup key for the coexist mode (Plan A): the user's full footer settings
-- table is snapshotted before we mutate items/all_at_once, and restored
-- verbatim on disable. Stored under the global settings store, not the
-- per-book one; deleted when no longer needed.
local BACKUP_KEY = "footer_pre_wifiicon_backup"

-- Items kept visible alongside the wifi icon in coexist mode. The K4 800px
-- bar cannot fit the full default set, so Plan A collapses to essentials;
-- battery/time are opt-in via COEXIST_EXTRA_ITEMS.
local COEXIST_KEEP = { page_progress = true, wifi_status = true }
local COEXIST_EXTRA_ITEMS = {}

local function is_backup(store)
    local t = store and store.readSetting and store:readSetting(BACKUP_KEY)
    return type(t) == "table"
end

local function backup_footer_settings(store)
    -- nil/malformed store (bare embeds, exotic hosts): no snapshot possible;
    -- callers must treat "false" as "collapse is FORBIDDEN" so the v5.7
    -- single-mode contract stays the safe fallback.
    if type(store) ~= "table" or type(store.readSetting) ~= "function"
            or type(store.saveSetting) ~= "function" then
        return false
    end
    if is_backup(store) then
        return false
    end
    local fs = store:readSetting("footer")
    if type(fs) ~= "table" then
        return false
    end
    store:saveSetting(BACKUP_KEY, M.deep_copy(fs))
    return true
end

local function restore_footer_settings(store)
    local backup = store:readSetting(BACKUP_KEY)
    if type(backup) ~= "table" then
        return false
    end
    store:saveSetting("footer", M.deep_copy(backup))
    store:saveSetting(BACKUP_KEY, nil)
    return true
end

-- Collapse an all_at_once item set down to the coexist essentials
-- (page_progress + wifi_status + opted-in extras). Returns a mutated copy.
-- MUST only be called after backup_footer_settings() returned true: a
-- collapse without a snapshot is unrecoverable for the user's item mix.
local function apply_coexist_items(fs)
    for key, _ in pairs(fs) do
        if COEXIST_KEEP[key] then
            fs[key] = true
        elseif type(fs[key]) == "boolean" then
            fs[key] = false
        end
    end
    fs.page_progress = true
    fs.wifi_status = true
    fs.all_at_once = true
    for _, name in ipairs(COEXIST_EXTRA_ITEMS) do
        fs[name] = true
    end
    return fs
end

-- Apply wifi_status on a live footer and run the native refresh bookkeeping.
-- Returns true when the footer was touched.
function M.apply_to_footer(footer, enabled)
    if type(footer) ~= "table" or type(footer.settings) ~= "table" then
        return false
    end
    enabled = enabled == true
    local plan_a_backup = false
    -- Plan A coexist: on enable, snapshot once so disable can restore the
    -- user's original item mix verbatim. The live footer.settings IS the
    -- persisted "footer" table (KOReader mirrors it), but a user who never
    -- touched the status bar has no "footer" key in the store: persist the
    -- pre-state FIRST, then snapshot it -- collapsing an un-captured state
    -- is forbidden (restore guarantee). No snapshot possible (bare store)?
    -- plan_a_backup stays false and the v5.7 single-mode contract below
    -- runs unchanged. On disable, restore the snapshot before the native
    -- bookkeeping so it sees the user's original item mix.
    if enabled then
        if not is_backup(_G.G_reader_settings) then
            local store = get_store()
            local persisted = store and store:readSetting("footer") or nil
            if store and type(store.saveSetting) == "function"
                    and type(persisted) ~= "table" then
                store:saveSetting("footer", M.deep_copy(footer.settings))
            end
            plan_a_backup = backup_footer_settings(store)
        end
    elseif is_backup(_G.G_reader_settings) then
        restore_footer_settings(_G.G_reader_settings)
        local restored = _G.G_reader_settings:readSetting("footer")
        if type(restored) == "table" then
            for key, value in pairs(restored) do
                footer.settings[key] = type(value) == "table" and M.deep_copy(value) or value
            end
            -- The mode pointer may still sit on the coexist wifi position
            -- set at enable time; the restored mix has wifi off, so re-point
            -- it at page progress (the v5.7 disable contract) before the
            -- native bookkeeping below renders with the restored table.
            if not footer.settings.all_at_once then
                local positions = M.compute_mode_positions(footer.settings)
                local page_pos = positions and positions.page_progress
                if page_pos and footer.applyFooterMode then
                    footer:applyFooterMode(page_pos)
                    M.save_reader_footer_mode(page_pos)
                end
            end
        end
    end
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
        if type(footer.updateFooterTextGenerator) == "function" then
            should_update = footer:updateFooterTextGenerator()
        else
            -- degraded host: the state above is already consistent, force
            -- the repaint through the generic path below
            should_update = true
        end
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
    elseif enabled and not footer.settings.all_at_once then
        -- K4/non-touch specific (v5.7 compact design): the single-mode footer
        -- cannot be cycled without a touchscreen (footer tap zone is dead and
        -- the "Toggle mode" menu item only exists when the tap zone is zeroed),
        -- so a natively "quiet join" would leave the icon unreachable. Switch
        -- the displayed mode to the wifi item itself: the footer then shows
        -- one small glyph plus the progress bar -- the smallest persistent
        -- footprint, symmetric with disable (which restores page progress).
        local wifi_mode = footer.mode_list and footer.mode_list.wifi_status
        if wifi_mode then
            if footer.applyFooterMode then
                footer:applyFooterMode(wifi_mode)
            else
                footer.mode = wifi_mode
            end
            M.save_reader_footer_mode(footer.mode)
            should_update = true
        end
    end

    if should_update or should_signal then
        if type(footer.refreshFooter) == "function" then
            footer:refreshFooter(should_update, should_signal)
        elseif type(footer.onUpdateFooter) == "function" then
            -- degraded host: plain repaint, no margin signalling
            footer:onUpdateFooter(should_update)
        end
    end
    if footer.rescheduleFooterAutoRefreshIfNeeded then
        footer:rescheduleFooterAutoRefreshIfNeeded()
    end
    if enabled and plan_a_backup then
        -- Coexist now: collapse the item set to page progress + the icon (plus
        -- opted-in extras) and switch to all_at_once, so page numbers survive.
        apply_coexist_items(footer.settings)
        if type(footer.updateFooterTextGenerator) == "function" then
            footer:updateFooterTextGenerator()
        end
        local positions = M.compute_mode_positions(footer.settings)
        local wifi_pos = positions and positions.wifi_status
        if wifi_pos then
            if footer.applyFooterMode then
                footer:applyFooterMode(wifi_pos)
            else
                footer.mode = wifi_pos
            end
            M.save_reader_footer_mode(wifi_pos)
        end
        if type(footer.refreshFooter) == "function" then
            footer:refreshFooter(true, true)
        end
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
    -- Plan A coexist on the store path (file manager / next-book-open):
    -- snapshot once, collapse to page progress + icon; restore verbatim on
    -- disable. fs may be a fresh seed table (KOReader defaults) that exists
    -- nowhere yet: persist the PRE-state first, snapshot it, and only then
    -- collapse -- otherwise a disable could never bring the user's items
    -- back. A failed snapshot keeps the legacy single-mode contract (no
    -- collapse), so enable is never a lossy operation.
    if enabled then
        if not is_backup(store) then
            store:saveSetting("footer", M.deep_copy(fs))
        end
        if backup_footer_settings(store) then
            apply_coexist_items(fs)
        end
    elseif is_backup(store) then
        restore_footer_settings(store)
        fs = store:readSetting("footer")
        if type(fs) ~= "table" then
            fs = {}
        end
    end
    fs.wifi_status = enabled
    store:saveSetting("footer", fs)
    -- Mirror the reader-context contract for the coexist layout (Plan A):
    -- enable points the persisted mode at the wifi item so the icon shows up
    -- next to page progress on next book open; disable restores the mode
    -- only when it points at wifi (a mode the user set himself is kept).
    -- all_at_once IS flipped now (Plan A coexist, see above) -- the v5.7
    -- "never touch all_at_once" rule was superseded: the collapse keeps the
    -- bar at page_progress + icon, and the pre-A item mix rides out in the
    -- backup key. The position is COMPUTED (device gates + optional custom
    -- order), never hardcoded: the
    -- previous constant 11 is the MODE value, but reader_footer_mode is a
    -- 0-based mode_index position, and on a frontlight-less K4 wifi_status
    -- sits at position 10 -- hardcoded 11 silently selected "book_title"
    -- instead of the icon (v5.7 fix).
    if store.saveSetting then
        local positions = M.compute_mode_positions(fs)
        local wifi_pos = positions and positions.wifi_status or nil
        if enabled then
            if wifi_pos then
                store:saveSetting("reader_footer_mode", wifi_pos)
            else
                logger.warn("wifi_status unavailable on this device; reader_footer_mode left unchanged")
            end
        elseif wifi_pos ~= nil
                and store:readSetting("reader_footer_mode") == wifi_pos then
            store:saveSetting("reader_footer_mode", positions.page_progress or 1)
        end
    end
    M.flush_store()
    return true
end

return M
