local I18n = require("weread.lib.i18n")
local T = require("ffi/util").template
local logger = require("weread.lib.logger")

local PluginUtil = {
    T = T,
    unpack_args = unpack or table.unpack,
}

-- Wrap a plugin event handler so a Lua error can never propagate into
-- KOReader's core event loop. KOReader's event propagation
-- (WidgetContainer:propagateEvent) is NOT pcall-protected: an exception
-- inside ReaderUI:onClose()'s CloseDocument broadcast aborts the teardown
-- (document stays open, reader stays on screen), which is exactly the
-- reported "confirm exit but remain in the reader" bug. Guarding every
-- on* entry point keeps the plugin failure-isolated: log the traceback
-- and report the event as unhandled (nil) so the chain keeps running.
function PluginUtil.event_handler(label, handler)
    return function(self, ...)
        -- Varargs cannot be captured as upvalues; snapshot them explicitly
        -- so the guarded closure below can forward them.
        local args = { ... }
        local results = { xpcall(function()
            return handler(self, PluginUtil.unpack_args(args))
        end, debug.traceback) }
        if not results[1] then
            logger.err("event handler failed:",
                tostring(label), PluginUtil.log_error(results[2]))
            return nil
        end
        return select(2, PluginUtil.unpack_args(results))
    end
end

function PluginUtil.tr(text)
    return I18n.tr(text)
end

function PluginUtil.log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

function PluginUtil.display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

function PluginUtil.file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

-- Recursively create a directory with lfs (replaces `os.execute("mkdir -p")`,
-- removing the shell dependency / injection surface). Returns true on success
-- or when the path already exists; (false, err) on failure.
function PluginUtil.mkdirs(path)
    if type(path) ~= "string" or path == "" then
        return false, "invalid path"
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or type(lfs.mkdir) ~= "function" then
        return false, "lfs unavailable"
    end
    local current = ""
    for part in path:gmatch("[^/]+") do
        current = current .. "/" .. part
        local mode = lfs.attributes(current, "mode")
        if not mode then
            local mk_ok = lfs.mkdir(current)
            if not mk_ok and lfs.attributes(current, "mode") ~= "directory" then
                return false, "mkdir failed: " .. current
            end
        elseif mode ~= "directory" then
            return false, "path not a directory: " .. current
        end
    end
    return true
end

return PluginUtil
