-- weread/lib/last_read.lua
-- v9.1 (K4weread): last-read WeRead book tracking for the weread-only
-- launch mode.
--
-- The plugin records the last opened WeRead book path on ReaderReady (see
-- reader_lifecycle.onReaderReady); the weread-only autostart reopens it
-- directly (main.lua) and falls back to the bookshelf when nothing is
-- recorded or the cached file has disappeared. Non-WeRead documents never
-- update the record (detectWeReadBook gates the call), so "last read" here
-- always means the last WeRead book — which is what the weread-only entry
-- should reopen.
--
-- Pure module: settings and filesystem access are injected or pcall-guarded.
-- Failure means "fall back to the bookshelf", never a broken launch.

local logger = require("weread.lib.logger")

local M = {}

-- Settings key holding { path = "..." } (single table keeps future fields
-- like book_id available without a migration).
M.SETTINGS_KEY = "weread_only_last"

-- Injectable fs surface (specs replace this; device default uses stdlib).
M._fs = {
    exists = function(path)
        local f = io.open(path, "r")
        if not f then return false end
        f:close()
        return true
    end,
}

-- Remember the path of the last opened WeRead book. Best-effort: a settings
-- write failure must never break the reader flow.
function M.record(settings, path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local ok, err = pcall(function()
        settings:set(M.SETTINGS_KEY, { path = path })
    end)
    if not ok then
        logger.warn("last-read record failed:", tostring(err))
        return false
    end
    return true
end

-- Return the path to reopen, or nil when the caller should show the
-- bookshelf instead. Guards every step: corrupted settings, empty paths and
-- fs probe surprises all degrade to nil.
function M.pick(settings, fs)
    local exists = fs and fs.exists or M._fs.exists

    local ok, entry = pcall(function()
        return settings:get(M.SETTINGS_KEY)
    end)
    if not ok or type(entry) ~= "table" then
        return nil
    end

    local path = entry.path
    if type(path) ~= "string" or path == "" then
        return nil
    end

    local ok_fs, found = pcall(exists, path)
    if not ok_fs or not found then
        return nil
    end
    return path
end

-- v9.4: weread-only autostart entry decision. Returns:
--   "book"  → a readable last-read book exists (works offline; reading a
--             cached book never required login, so book beats login)
--   "login" → fresh/never-logged-in device — the QR login must be the
--             explicit first-run landing (a bookshelf attempt would just be
--             gated by requireLogin and never render)
--   "shelf" → logged in, nothing to reopen
-- `logged_in` is the caller's credential predicate (cookie AND api key),
-- mirroring requireLogin(true, true).
function M.pick_entry(settings, fs, logged_in)
    local path = M.pick(settings, fs)
    if path then
        return "book", path
    end
    if not logged_in then
        return "login"
    end
    return "shelf"
end

return M
