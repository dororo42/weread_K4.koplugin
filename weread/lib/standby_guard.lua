-- 2026-11-12: centralised lipc standby guard. downloader.lua sets
-- preventScreenSaver during chapter downloads so the device does not doze
-- mid-transfer (LIPC_STANDBY_GUARD_ENABLED gate), and clears it when the
-- download ends.
--
-- Residue problem (K4, 2026-11-14): a crash or forced kill mid-download
-- leaves powerd's preventScreenSaver at 1 with no one to clear it, arming
-- the KOReader AutoSuspend freeze mode (koreader#16194: residue + fresh Lua
-- state -> ~160 isCharging polls/second until the battery dies). The
-- plugin-init clear below defuses that: at init no download is running, so
-- any preventScreenSaver=1 seen there is stale residue. lipc failures are
-- non-fatal (devices without lipc just no-op).

local Device = require("device")
local logger = require("weread.lib.logger")

local M = {}

function M.clearPreventScreenSaverResidue()
    if Device:isKindle() then
        local cmd = "lipc-set-prop com.lab126.powerd preventScreenSaver 0"
        local ok, err = pcall(os.execute, cmd)
        if not ok then
            logger.warn("standby_guard: preventScreenSaver reset failed:",
                tostring(err))
        end
    end
end

function M.setPreventScreenSaver()
    if Device:isKindle() then
        local cmd = "lipc-set-prop com.lab126.powerd preventScreenSaver 1"
        pcall(os.execute, cmd)
    end
end

function M.clearPreventScreenSaver()
    if Device:isKindle() then
        local cmd = "lipc-set-prop com.lab126.powerd preventScreenSaver 0"
        pcall(os.execute, cmd)
    end
end

return M
