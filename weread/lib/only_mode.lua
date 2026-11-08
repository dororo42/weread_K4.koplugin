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
-- K4weread repository (writer side; that repo's check_marker_path.py pins
-- its side, this module pins ours via this comment + the spec).
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

function M.flag_path()
    return M.FLAG_DIR .. "/" .. M.FLAG_NAME
end

-- One-shot detection: consumes the flag when present and arms the session.
-- Idempotent: once armed, later calls are served from module state and never
-- touch the filesystem. Returns whether weread-only mode is active.
function M.detect_and_consume()
    if M._session_active then return true end

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
    local ok_rm, err = pcall(M._fs.remove, path)
    if not ok_rm then
        logger.warn("weread-only flag removal failed:", tostring(err))
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
end

return M
