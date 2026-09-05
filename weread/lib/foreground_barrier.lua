-- Foreground barrier: a short window after user interaction during which
-- background tasks defer themselves ("interaction first").
--
-- v4.5 (2026-08-28, borrowed from MiuRead's foreground barrier design):
-- the K4 build's page-turn deconfliction (P0-2) only covers the read-report
-- tick. This module generalises the idea: any interaction can raise the
-- barrier, and every background task (download steps, prefetch, ...) checks
-- it before doing work. Download steps re-schedule themselves while the
-- barrier is up, with a hard defer cap so a long interaction can never
-- starve a download.

local GlobalState = require("weread.lib.global_state")

local ForegroundBarrier = {}

-- Runtime state survives plugin reloads inside one KOReader process.
-- 原#2 收口 (2026-09-05): moved from its own rawget(_G, ...) key into the
-- shared global_state slot.
local state = GlobalState.get("foreground_barrier")
if type(state) ~= "table" then
    state = { until_at = 0, reason = nil }
    GlobalState.set("foreground_barrier", state)
end

-- How long the barrier stays up after an interaction (seconds).
local BARRIER_SECONDS = 2
-- Longest a single background step may be deferred (seconds).
local MAX_DEFER_SECONDS = 30

-- Raise the barrier. Extends an active window instead of shrinking it, so a
-- continuous interaction (fast page turning) keeps the barrier up.
function ForegroundBarrier.set(reason)
    local until_at = os.time() + BARRIER_SECONDS
    if until_at > state.until_at then
        state.until_at = until_at
        state.reason = tostring(reason or "interaction")
    end
end

function ForegroundBarrier.clear()
    state.until_at = 0
    state.reason = nil
end

function ForegroundBarrier.active()
    local now = os.time()
    if state.until_at <= now then
        if state.until_at ~= 0 then
            state.until_at = 0
            state.reason = nil
        end
        return false
    end
    return true
end

function ForegroundBarrier.remaining()
    return math.max(0, state.until_at - os.time())
end

-- Number of 0.5s deferrals allowed before a background step runs anyway.
function ForegroundBarrier.max_defers()
    return math.ceil(MAX_DEFER_SECONDS / 0.5)
end

return ForegroundBarrier
