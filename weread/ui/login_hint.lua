-- P1-C §六·3 (2026-09-18): persistent "login expired" hint in the KOReader
-- footer. The native wifi glyph cannot carry plugin state (see main.lua
-- on_session_expired comment), so the hint reuses the footer's own
-- custom_text item (MODE_ORDER entry, readerfooter.lua v2026.07.1):
--
--   enable flag : footer.settings.custom_text (boolean)
--   text        : footer.custom_text (instance attr, read at init from
--                 G_reader_settings "reader_footer_custom_text")
--   repetitions : footer.custom_text_repetitions (instance attr)
--
-- Static display ("常显") was chosen over blinking (E-ink refresh cost) and
-- over menu-only surfacing (already shipped as the Report status line). The
-- hint is only injected when the footer runs in all_at_once mode: on the K4
-- non-touch single-mode footer, switching the displayed mode to custom_text
-- would hide page progress, which is an unacceptable trade for a hint.
--
-- Injection is fully reversible: the pre-state is snapshotted under
-- G_reader_settings (footer_weread_login_hint_backup) BEFORE the first
-- mutation, so a power loss mid-episode cannot strand the footer with the
-- hint text. hide() restores the snapshot verbatim. Both paths are pcall
-- guarded and degrade to a no-op outside a live ReaderUI (nil-safe).
local FI = require("weread/ui/footer_indicator")
local logger = require("weread/lib.logger")

local M = {}

-- Snapshot key in G_reader_settings. Presence == "hint currently injected".
local BACKUP_KEY = "footer_weread_login_hint_backup"

-- G_reader_settings keys read by ReaderFooter:init (v2026.07.1).
local G_TEXT_KEY = "reader_footer_custom_text"
local G_REPS_KEY = "reader_footer_custom_text_repetitions"

local function get_store()
    local store = _G.G_reader_settings
    if type(store) == "table" and type(store.readSetting) == "function" then
        return store
    end
    return nil
end

local function save(store, key, value)
    if type(store) == "table" and type(store.saveSetting) == "function" then
        pcall(store.saveSetting, store, key, value)
    end
end

local function read(store, key)
    if type(store) == "table" and type(store.readSetting) == "function" then
        local ok, value = pcall(store.readSetting, store, key)
        if ok then return value end
    end
    return nil
end

-- Repaint through the native all_at_once path, then a generic refresh.
-- Refresh failures are logged, never raised: the hint state is already
-- written, a failed repaint only delays the visual.
function M._repaint(footer)
    local ok, err = pcall(function()
        if type(footer.updateFooterTextGenerator) == "function" then
            footer:updateFooterTextGenerator()
        end
        if type(footer.refreshFooter) == "function" then
            footer:refreshFooter(true, true)
        elseif type(footer.onUpdateFooter) == "function" then
            footer:onUpdateFooter(true)
        end
    end)
    if not ok then
        logger.warn("login_hint repaint failed:", tostring(err))
    end
end

-- True while a hint is (or was) injected, per the persisted snapshot.
-- Works without a live footer (FileManager context, after a restart).
function M.is_active()
    local store = get_store()
    return type(read(store, BACKUP_KEY)) == "table"
end

-- Inject the hint text. Returns true when the footer now shows it.
-- text: caller-provided display string (i18n'ed by the caller).
function M.show(ui, text)
    local footer = FI.resolve_footer(ui)
    if not footer then
        return false, "no_footer"
    end
    if type(footer.settings) ~= "table" then
        return false, "no_settings"
    end
    -- Single-mode footer (K4 non-touch, Plan A not enabled): switching the
    -- displayed mode to custom_text would replace page progress. Refuse.
    if footer.settings.all_at_once ~= true then
        return false, "single_mode"
    end
    local store = get_store()
    if not store then
        return false, "no_store"
    end
    -- Snapshot once per episode; a repeat show() only refreshes the text
    -- (idempotent under repeated expiry callbacks).
    local backup = read(store, BACKUP_KEY)
    if type(backup) ~= "table" then
        backup = {
            enabled = footer.settings.custom_text == true,
            text = footer.custom_text,
            repetitions = footer.custom_text_repetitions,
            g_text = read(store, G_TEXT_KEY),
            g_repetitions = read(store, G_REPS_KEY),
        }
        save(store, BACKUP_KEY, backup)
    end
    text = (type(text) == "string" and text ~= "") and text or "WeRead"
    footer.custom_text = text
    footer.custom_text_repetitions = 1
    footer.settings.custom_text = true
    save(store, G_TEXT_KEY, text)
    save(store, G_REPS_KEY, 1)
    M._repaint(footer)
    FI.flush_store()
    return true
end

-- Remove the hint and restore the pre-episode state. Safe to call at any
-- time (no snapshot / no footer -> no-op). Returns true when restored.
function M.hide(ui)
    local store = get_store()
    local backup = read(store, BACKUP_KEY)
    if type(backup) ~= "table" then
        return false
    end
    -- Snapshot cleared FIRST: if anything below fails, the worst case is the
    -- user's previous custom text staying hidden, not a stale hint that no
    -- hide() call can ever clear again.
    save(store, BACKUP_KEY, nil)
    -- Restore the persisted layer to its pre-episode shape (nil deletes the
    -- key, matching "user never customized it" as ReaderFooter:init expects).
    if backup.g_text == nil then
        save(store, G_TEXT_KEY, nil)
    else
        save(store, G_TEXT_KEY, backup.g_text)
    end
    if backup.g_repetitions == nil then
        save(store, G_REPS_KEY, nil)
    else
        save(store, G_REPS_KEY, backup.g_repetitions)
    end
    local footer = FI.resolve_footer(ui)
    if footer and type(footer.settings) == "table" then
        footer.settings.custom_text = backup.enabled == true
        footer.custom_text = type(backup.text) == "string"
            and backup.text or footer.custom_text
        footer.custom_text_repetitions = tonumber(backup.repetitions) or 1
        M._repaint(footer)
    end
    FI.flush_store()
    return true
end

-- R-3 (2026-09-19, review): the other footer injector (footer_indicator's
-- Plan A backup) restores the footer table WHOLESALE on disable, which can
-- wipe this hint's injection while the episode is still active. Call this
-- after any such restore: re-asserts the hint keys. The display text comes
-- from the persisted G-layer key (login_hint.show keeps it current for the
-- whole episode), NOT from the pre-episode backup. No-op unless a hint
-- episode is active; never raises.
function M.reassert(footer)
    local store = get_store()
    local backup = read(store, BACKUP_KEY)
    if type(backup) ~= "table" then
        return false
    end
    if type(footer) ~= "table" or type(footer.settings) ~= "table" then
        return false
    end
    local text = read(store, G_TEXT_KEY)
    footer.settings.custom_text = true
    if type(text) == "string" and text ~= "" then
        footer.custom_text = text
    end
    footer.custom_text_repetitions = 1
    M._repaint(footer)
    return true
end

return M
