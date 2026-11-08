-- weread/lib/only_mode.lua
-- v9.0 (K4weread): weread-only launch mode — marker flag consume semantics.
--
-- Handshake contract (K4weread repo, docs/DESIGN.md §4): the K4weread KUAL
-- extension touches /mnt/us/k4weread/launch.flag before starting KOReader;
-- the first plugin instance to init consumes it (read + delete) and arms a
-- module-level session state. Later plugin instances in the same process
-- (FileManager -> ReaderUI handoff) query is_active() without the file, so
-- the flag is consumed exactly once per KOReader session.
--
-- The path literal must stay in sync with kual/bin/k4weread.sh in the
-- K4weread repository (writer side). Both sides are now machine-checked:
--   * this repo: spec/only_mode_spec.lua pins the production literal;
--   * peer repo: tools/check_marker_path.py --peer-repo compares both.
--
-- Flag handling is advisory: every filesystem access is guarded so a probe
-- surprise can never break plugin init (same posture as credential_store's
-- pcall-wrapped symbol probing). Failure means "stay in normal mode", never
-- a crash.

local logger = require("weread.lib.logger")

local M = {}

-- Device paths (overridable for specs; see the K4weread repo contract).
M.FLAG_DIR = "/mnt/us/k4weread"
M.FLAG_NAME = "launch.flag"

-- Injectable fs surface: specs replace this; the device default uses the
-- standard library only (no ffi, no KOReader modules).
M._fs = {
    exists = function(path)
        local f = io.open(path, "r")
        if not f then return false end
        f:close()
        return true
    end,
    remove = function(path)
        return os.remove(path)
    end,
}

-- Session state shared by every plugin instance in this Lua VM (KOReader
-- caches modules, so both the FM and Reader instances see the same table).
M._session_active = false

-- 2026-11-08 audit: a flag that was observed but could not be deleted would
-- otherwise stay on disk and hijack a later session started without the KUAL
-- full-mode escape hatch. Retry the cleanup on every later init.
M._pending_remove = false

function M.flag_path()
    return M.FLAG_DIR .. "/" .. M.FLAG_NAME
end

-- One-shot detection: consumes the flag when present and arms the session.
-- Idempotent: once armed, later calls are served from module state and never
-- touch the filesystem (except a deferred cleanup retry, see below).
-- Returns whether weread-only mode is active.
function M.detect_and_consume()
    if M._session_active then
        if M._pending_remove then
            local ok_retry, removed = pcall(M._fs.remove, M.flag_path())
            if ok_retry and removed then
                M._pending_remove = false
                logger.info("weread-only stale flag removed on retry")
            end
        end
        return true
    end

    local path = M.flag_path()
    local ok, exists = pcall(M._fs.exists, path)
    if not ok or not exists then
        if not ok then
            logger.warn("weread-only flag probe failed, staying in normal mode")
        end
        return false
    end

    -- The flag was observed: arm the session even if the delete fails
    -- (deletion is best-effort cleanup; the user asked for this mode).
    local ok_rm, removed = pcall(M._fs.remove, path)
    if not ok_rm or not removed then
        M._pending_remove = true
        logger.err("weread-only flag removal failed, cleanup deferred:",
            tostring(removed))
    end

    M._session_active = true
    logger.info("weread-only launch flag consumed:", path)
    return true
end

function M.is_active()
    return M._session_active
end

-- Test hook: restores pristine state for independent spec runs.
function M._reset()
    M._session_active = false
    M._pending_remove = false
end

return M
