-- 原#2 收口 (2026-09-05): the single sanctioned _G slot for state that must
-- outlive a plugin instance. openFile() rebuilds ReaderUI (and every plugin
-- instance) mid-flow, so a few pieces of state cannot live on the instance;
-- historically each feature grabbed its own rawget(_G, ...) key. Everything
-- now shares ONE namespaced slot with explicit get/set/clear so the set of
-- cross-instance state stays auditable.
--
-- Keys currently in use:
--   pending_chapter_goto   { data = {...} }   reader_lifecycle / ui.library
--   dialog_stack           { widget, ... }    ui.common trackDialog
--   foreground_barrier     { until_at, reason } lib.foreground_barrier
--
-- Values live in process memory only (never persisted); a KOReader restart
-- resets everything, which is the intended lifecycle.
local KEY = "__WEREAD_SHARED_STATE"

local M = {}

local function shared()
    local state = rawget(_G, KEY)
    if type(state) ~= "table" then
        state = {}
        rawset(_G, KEY, state)
    end
    return state
end

function M.get(name)
    if type(name) ~= "string" then return nil end
    return shared()[name]
end

function M.set(name, value)
    if type(name) ~= "string" then return end
    shared()[name] = value
end

function M.clear(name)
    if type(name) ~= "string" then return end
    shared()[name] = nil
end

return M
