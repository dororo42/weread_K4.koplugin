local Content = require("weread.lib.content")
local logger = require("weread.lib.logger")

local PluginUtil = require("weread.lib.plugin_util")
local log_error = PluginUtil.log_error

local Migrations = {}

-- v4.0 migration: UA 已切换为 Edge-Windows（protocol.lua USER_AGENT），
-- 基于旧 UA（Edge-macOS）计算的持久化 book.app_id 与当前 UA 不匹配。
-- 若沿用会形成"请求头 UA 与 payload app_id 声称设备不一致"，触发风控。
-- 一次性清除全部 book.app_id，由 read_report.lua 的
-- book.app_id or WeRead.web_app_id() 三处用新 UA 自动重算并重新持久化。
-- 用独立标记保证只执行一次，避免反复清掉已重算的新值。
local function clear_stale_app_ids(settings)
    if settings:get("v4_ua_app_id_migration_done") then
        return
    end
    local books = settings:get("books", {})
    local cleared = 0
    for _book_id, book in pairs(books) do
        if type(book) == "table" and book.app_id ~= nil then
            book.app_id = nil
            cleared = cleared + 1
        end
    end
    local ok, err = pcall(function()
        settings:set("books", books)
        settings:set("v4_ua_app_id_migration_done", true)
        settings:flush()
    end)
    if ok then
        logger.info("stale book.app_id cleared for UA switch:",
            "cleared=", tostring(cleared))
    else
        logger.err("stale app_id migration failed:", log_error(err))
    end
end

function Migrations.run(settings, client)
    -- v4.0: UA 切换（Edge-macOS → Edge-Windows）后清除旧 app_id。
    -- 放在最前：即使下方 catalog 迁移提前 return，清理也必定执行。
    clear_stale_app_ids(settings)

    local books = settings:get("books", {})
    local found, migrated, failed = false, 0, 0
    for _book_id, book in pairs(books) do
        if type(book) == "table" and book.chapters ~= nil then
            found = true
            if type(book.chapters) == "table" then
                local ok, saved = pcall(Content.save_catalog_cache,
                    client, settings, book, book.chapters)
                if ok and saved then
                    -- H-1 fix: only clear in-memory chapters after the catalog
                    -- cache is confirmed on disk. On IO failure keep the
                    -- original data so the next run can retry.
                    book.chapters = nil
                    migrated = migrated + 1
                else
                    failed = failed + 1
                end
            else
                book.chapters = nil
            end
        end
    end
    if not found and not settings:has_legacy_book_records() then
        return
    end

    local ok, err = pcall(function()
        settings:set("books", books)
        settings:flush()
    end)
    if ok then
        logger.info("legacy per-book data migrated:",
            "catalogs=", tostring(migrated),
            "catalog_failures=", tostring(failed))
    else
        logger.err("legacy per-book data migration failed:",
            log_error(err))
    end
end

return Migrations
