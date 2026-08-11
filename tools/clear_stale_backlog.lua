-- clear_stale_backlog.lua
--
-- 一次性维护脚本：清除 weread.lua 中所有书籍的陈旧 watermark / pending_backlog。
--
-- 适用场景：
--   从 v3.0（pending_backlog 修复前）升级到 v3.x 的用户，旧版本可能遗留
--   大量非阅读时间累积的 backlog（睡眠/离开时间被当作阅读时间）。直接补报
--   会污染账号数据并触发服务器风控。本脚本清除所有书籍的 watermark /
--   pending_backlog / last_active 字段，让 v3.x 从干净状态重新开始累计。
--
-- 执行方式（任选其一）：
--   方式 A（KUAL 菜单）：将本文件放到 KOReader scripts 目录，通过 KUAL 触发
--   方式 B（KOReader 终端）：在 KOReader 的终端中执行
--       dofile("/path/to/clear_stale_backlog.lua")
--   方式 C（USB + 文件管理器）：USB 连接设备，手动编辑 weread.lua 删除
--       read_report.watermarks 表（最简单，见下方"手动编辑"说明）
--
-- 安全保证：
--   1. 执行前自动备份 weread.lua → weread.lua.bak.YYYYMMDDHHMMSS
--   2. 仅清除 read_report.watermarks 字段，不动其他配置（cookies/books/...）
--   3. 全程 pcall 保护，失败时回滚
--   4. 输出详细的清除前后对比，便于核对

local DataStorage = require("datastorage")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local settings_file = DataStorage:getSettingsDir() .. "/weread.lua"

-- ------------------------------------------------------------------
-- 工具函数
-- ------------------------------------------------------------------

local function file_exists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function file_size(path)
    local attr = lfs.attributes(path)
    return attr and attr.size or 0
end

local function timestamp()
    return os.date("%Y%m%d%H%M%S")
end

local function copy_file(src, dst)
    local src_f, err = io.open(src, "rb")
    if not src_f then return false, err end
    local dst_f, err2 = io.open(dst, "wb")
    if not dst_f then src_f:close(); return false, err2 end
    local content = src_f:read("*a")
    src_f:close()
    dst_f:write(content)
    local ok, werr = dst_f:close()
    if not ok then return false, werr end
    return true
end

-- ------------------------------------------------------------------
-- 主流程
-- ------------------------------------------------------------------

local function main()
    print("[clear_stale_backlog] starting")

    -- 1. 检查文件存在
    if not file_exists(settings_file) then
        print("[clear_stale_backlog] settings file not found: " .. settings_file)
        print("[clear_stale_backlog] nothing to do (fresh install?)")
        return true
    end

    local size_before = file_size(settings_file)
    print("[clear_stale_backlog] settings file: " .. settings_file)
    print(string.format("[clear_stale_backlog] size before: %d bytes", size_before))

    -- 2. 备份
    local backup_path = settings_file .. ".bak." .. timestamp()
    local ok, err = copy_file(settings_file, backup_path)
    if not ok then
        print("[clear_stale_backlog] BACKUP FAILED: " .. tostring(err))
        print("[clear_stale_backlog] aborting (no changes made)")
        return false
    end
    print("[clear_stale_backlog] backup created: " .. backup_path)

    -- 3. 加载 LuaSettings
    local LuaSettings = require("luasettings")
    local store = LuaSettings:open(settings_file)

    -- 4. 读取 read_report 配置
    local read_report = store:readSetting("read_report")
    if type(read_report) ~= "table" then
        print("[clear_stale_backlog] read_report config not a table (or missing)")
        print("[clear_stale_backlog] nothing to clear")
        return true
    end

    -- 5. 显示清除前的 watermarks
    local watermarks = read_report.watermarks
    if type(watermarks) == "table" then
        local count = 0
        local total_pending = 0
        for book_id, entry in pairs(watermarks) do
            if type(entry) == "table" then
                count = count + 1
                local pending = tonumber(entry.pending_backlog) or 0
                local wm = tonumber(entry.watermark) or 0
                local last_active = tonumber(entry.last_active) or 0
                total_pending = total_pending + pending
                print(string.format("  [before] book=%s watermark=%d last_active=%d pending_backlog=%d (%.1f min)",
                    tostring(book_id), wm, last_active, pending, pending / 60.0))
            end
        end
        print(string.format("[clear_stale_backlog] found %d book entries, total pending = %d seconds (%.1f min)",
            count, total_pending, total_pending / 60.0))
    else
        print("[clear_stale_backlog] read_report.watermarks not a table (type=" .. type(watermarks) .. ")")
        print("[clear_stale_backlog] nothing to clear")
        return true
    end

    -- 6. 清除 watermarks 和遗留的全局 watermark
    read_report.watermarks = {}
    -- 同时清除 v3.0 之前的遗留全局 watermark 字段（若存在）
    if read_report.watermark ~= nil then
        print(string.format("[clear_stale_backlog] clearing legacy global watermark = %s",
            tostring(read_report.watermark)))
        read_report.watermark = nil
    end
    store:saveSetting("read_report", read_report)

    -- 7. 持久化
    local flush_ok, flush_err = pcall(function() store:flush() end)
    if not flush_ok then
        print("[clear_stale_backlog] FLUSH FAILED: " .. tostring(flush_err))
        print("[clear_stale_backlog] restoring from backup: " .. backup_path)
        copy_file(backup_path, settings_file)
        return false
    end

    local size_after = file_size(settings_file)
    print(string.format("[clear_stale_backlog] size after:  %d bytes", size_after))
    print("[clear_stale_backlog] DONE — all book watermarks / pending_backlog cleared")
    print("[clear_stale_backlog] v3.x will start fresh; future offline reading time")
    print("[clear_stale_backlog]   will be carried over correctly via pending_backlog")
    print("[clear_stale_backlog] backup retained at: " .. backup_path)
    print("[clear_stale_backlog] if anything looks wrong, restore it manually via USB")
    return true
end

local ok, err = pcall(main)
if not ok then
    print("[clear_stale_backlog] FATAL: " .. tostring(err))
    print("[clear_stale_backlog] no changes were committed to settings")
end
