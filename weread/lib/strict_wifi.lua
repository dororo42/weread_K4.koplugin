-- R-1 (2026-10-26 unified review v2 §五 P1): strict semantics for the
-- native Wi-Fi footer icon.
--
-- KOReader's NetworkMgr:isWifiOn() answers "is the radio switched on" (on
-- the Kindle 4: /sys/class/net/wlan0 exists — sysfsWifiOn). ReaderFooter
-- renders that as a connected glyph, so the icon kept claiming a link all
-- through the 10/25 airplane segment: the radio stayed on with NO AP
-- association (device log: zero "wlan0 is up" lines, then "Wi-Fi
-- successfully restored" 8s after landing — KOReader only restores a radio
-- it believes was on the whole time). The plugin's background layer uses
-- the address-based link-state check and behaved correctly all day; the
-- icon was the only liar.
--
-- install(network_mgr) wraps isWifiOn so "on" additionally requires the
-- interface to be operational (NetworkMgr:sysfsInterfaceOperational) and
-- to carry an address (NetworkMgr:ifHasAnAddress). Both primitives already
-- exist in the device KOReader (manager.lua:221-285) and both are already
-- what the background chain relies on. Guardrails:
--   * every probe is pcall'd; a probe that is missing or ERRORS degrades to
--     "pass" — the wrapper can never report a stricter-off state than stock
--     semantics, so it cannot introduce a new failure mode;
--   * idempotent: a second install is a no-op returning true;
--   * unexpected surfaces (no isWifiOn) return false, which main.lua logs
--     and ignores — stock behavior stays untouched.
-- The icon remains cosmetic (the K4 glyph cannot carry plugin state); the
-- authoritative offline judgment stays with isNetworkConnected().
local M = {}

-- Probe helpers are module-level so the wrap closure captures stable
-- references (and so a later monkey-patch of the mgr's probe functions
-- cannot move under a live install).
local function probe_passes(network_mgr, name)
    local fn = network_mgr[name]
    -- Primitive missing on this host: degrade to radio-only semantics.
    if type(fn) ~= "function" then
        return true
    end
    local ok, result = pcall(fn, network_mgr)
    -- Probe errored: never invent an "off" the stock code would not show.
    if not ok then
        return true
    end
    return result == true
end

function M.install(network_mgr)
    if type(network_mgr) ~= "table"
            or type(network_mgr.isWifiOn) ~= "function" then
        return false
    end
    if network_mgr._weread_strict_wifi then
        return true
    end
    local radio_on = network_mgr.isWifiOn
    network_mgr.isWifiOn = function(manager, ...)
        if not radio_on(manager, ...) then
            return false
        end
        return probe_passes(network_mgr, "sysfsInterfaceOperational")
            and probe_passes(network_mgr, "ifHasAnAddress")
    end
    network_mgr._weread_strict_wifi = true
    return true
end

return M
