-- Book/chapter download engine.
--
-- Extracted from main.lua as an independent, dependency-injected object so the
-- plugin entry point keeps only thin menu wrappers. The host injects the API
-- client, settings, and a small set of UI/framework callbacks; the engine owns
-- the whole async download state machine and the device standby guard.
--
-- Standby guard: long downloads must not let the device suspend mid-transfer.
-- Every scheduled step runs through _scheduleGuarded, which wraps the step in
-- xpcall and always releases the guard (and closes the dialog + reports the
-- error) if the step throws. This is critical: a bare UIManager:scheduleIn that
-- threw would leak the guard and leave the device unable to sleep until reboot.

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local logger = require("weread.lib.logger")
local time = require("ui/time")
local T = require("ffi/util").template

local Content = require("weread.lib.content")
local DownloadDialog = require("weread.ui.download_dialog")
local Footnotes = require("weread.lib.footnotes")
local I18n = require("weread.lib.i18n")
local PluginUtil = require("weread.lib.plugin_util")
local WeRead = require("weread.lib.protocol")

local function _(text)
    return I18n.tr(text)
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

-- Block OS-level standby (Kindle powerd, Kobo lid/menu-suspend, etc.)
local function preventOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = true
    end
end

local function allowOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = false
    end
end

local Downloader = {}
Downloader.__index = Downloader

-- o = {
--   client, settings,                       -- injected dependencies
--   show_info(text), show_transient(text, timeout),
--   refresh_ui(), refresh_shelf(),
--   open_file(path), safe_callback(label, fn),
--   require_login(cookie, api_key), run_online_task(label, fn),  -- host framework
-- }
function Downloader:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

-- Keep the device awake during long book downloads (reference counted so
-- multiple concurrent jobs share a single guard).
function Downloader:_beginStandby()
    self._standby_ref = (self._standby_ref or 0) + 1
    if self._standby_ref == 1 then
        UIManager:preventStandby()
        preventOsStandby()
    end
end

function Downloader:_endStandby()
    local ref = self._standby_ref or 0
    if ref <= 0 then
        return
    end
    self._standby_ref = ref - 1
    if self._standby_ref == 0 then
        UIManager:allowStandby()
        allowOsStandby()
    end
end

function Downloader:_releaseStandby(dl)
    if dl and dl.standby_guard then
        dl.standby_guard = nil
        self:_endStandby()
    end
end

function Downloader:_notifyCompletion(dl, ok, value)
    if not dl or dl.completion_notified then return end
    dl.completion_notified = true
    if type(dl.on_complete) ~= "function" then return end
    local called, err = pcall(dl.on_complete, ok == true, value)
    if not called then
        logger.warn("download completion callback failed:",
            log_error(err))
    end
end

function Downloader:_finishJob(dl)
    if self._active_job == dl then
        self._active_job = nil
    end
    local pending = self._pending_start
    if pending and not self._active_job then
        self._pending_start = nil
        local scheduled = { pending = pending }
        self._scheduled_start = scheduled
        UIManager:scheduleIn(0.1, function()
            if self._scheduled_start ~= scheduled then return end
            self._scheduled_start = nil
            self:start(pending.book, pending.chapters, pending.suffix, pending.options)
        end)
    end
end

function Downloader:_cancelScheduledPrefetch(reason)
    local scheduled = self._scheduled_start
    local pending = scheduled and scheduled.pending
    if not pending or not pending.options or not pending.options.prefetch then
        return false
    end
    self._scheduled_start = nil
    local book = pending.book or {}
    local chapter = pending.chapters and pending.chapters[1] or {}
    logger.info("scheduled prefetch cancelled:",
        "book_id=", tostring(book.book_id or book.bookId or ""),
        "chapter_uid=", tostring(chapter.chapterUid or chapter.chapterId or ""),
        "reason=", tostring(reason or "cancelled"))
    return true
end

function Downloader:getActivePrefetch()
    local job = self._active_job
    if job and job.prefetch and not job.cancelled then
        return job
    end
end

function Downloader:cancelPrefetch(reason)
    local cancelled_scheduled = self:_cancelScheduledPrefetch(reason)
    if self._pending_start and self._pending_start.options
        and self._pending_start.options.prefetch then
        local pending = self._pending_start
        local pending_book = pending.book or {}
        local pending_chapter = pending.chapters and pending.chapters[1] or {}
        logger.info("pending prefetch cancelled:",
            "book_id=", tostring(pending_book.book_id or pending_book.bookId or ""),
            "chapter_uid=", tostring(pending_chapter.chapterUid
                or pending_chapter.chapterId or ""),
            "reason=", tostring(reason or "cancelled"))
        self._pending_start = nil
    end
    local job = self:getActivePrefetch()
    if not job then return cancelled_scheduled end
    job.cancelled = true
    job.cancel_reason = reason or "cancelled"
    local chapter = job.chapters and job.chapters[1] or {}
    logger.info("active prefetch cancelled:",
        "book_id=", tostring(job.book
            and (job.book.book_id or job.book.bookId) or ""),
        "chapter_uid=", tostring(chapter.chapterUid or chapter.chapterId or ""),
        "reason=", tostring(job.cancel_reason))
    if job.progress_dialog then
        job.progress_dialog:close()
        job.progress_dialog = nil
    end
    return true
end

function Downloader:isPrefetching(book, chapter)
    local job = self:getActivePrefetch()
    local target = job and job.chapters and job.chapters[1]
    local job_book_id = job and job.book and (job.book.book_id or job.book.bookId)
    local book_id = book and (book.book_id or book.bookId)
    local target_uid = target and (target.chapterUid or target.chapterId)
    local chapter_uid = chapter and (chapter.chapterUid or chapter.chapterId)
    return job ~= nil
        and tostring(job_book_id or "") == tostring(book_id or "")
        and tostring(target_uid or "") == tostring(chapter_uid or "")
end

function Downloader:promotePrefetch(book, chapter)
    local job = self:getActivePrefetch()
    local target = job and job.chapters and job.chapters[1]
    local job_book_id = job and job.book and (job.book.book_id or job.book.bookId)
    local book_id = book and (book.book_id or book.bookId)
    local target_uid = target and (target.chapterUid or target.chapterId)
    local chapter_uid = chapter and (chapter.chapterUid or chapter.chapterId)
    if tostring(job_book_id or "") ~= tostring(book_id or "")
        or tostring(target_uid or "") ~= tostring(chapter_uid or "") then
        return false
    end
    job.open_on_complete = true
    job.promoted = true
    self:_ensureProgressDialog(job)
    return true
end

function Downloader:isPromotedPrefetch(book, chapter)
    return self:isPrefetching(book, chapter)
        and self._active_job.promoted == true
end

function Downloader:_ensureProgressDialog(dl)
    if dl.progress_dialog then return dl.progress_dialog end
    local progress_dialog = DownloadDialog:new{
        title = dl.stage_title or T(_("Downloading: %1"), dl.book.title or ""),
        progress_max = dl.total,
        buttons = {{
            {
                text = _("Cancel download"),
                callback = function()
                    dl.cancelled = true
                    dl.cancel_reason = dl.cancel_reason or "cancelled"
                    if dl.progress_dialog then
                        dl.progress_dialog:close()
                        dl.progress_dialog = nil
                    end
                end,
            },
        }},
    }
    dl.progress_dialog = progress_dialog
    progress_dialog:show()
    if dl.stage_progress then
        progress_dialog:reportProgress(dl.stage_progress)
    end
    self.refresh_ui()
    return progress_dialog
end

-- Schedule any download step behind xpcall so an uncaught error always releases
-- the standby guard, closes the progress dialog, and reports the failure.
function Downloader:_scheduleGuarded(dl, step_fn, delay)
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(step_fn, debug.traceback)
        if not ok and dl.standby_guard then
            self:_releaseStandby(dl)
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            logger.err("download step failed:", log_error(err))
            self:_notifyCompletion(dl, false, err)
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_("Download failed:\n%1"), display_error(err)))
            end
        end
    end)
end

-- Public entry: start downloading the given chapters as one EPUB.
function Downloader:start(book, chapters, suffix, options)
    options = options or {}
    chapters = type(chapters) == "table" and chapters or {}
    if options.prefetch and self.is_connected and not self.is_connected() then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "offline")
        end
        return false
    end
    if options.prefetch and self.settings.is_cookie_configured
        and not self.settings:is_cookie_configured() then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "authentication_required")
        end
        return false
    end
    if not options.prefetch and not self.require_login(true, false) then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "authentication_required")
        end
        return false
    end

    local scheduled = self._scheduled_start
    if scheduled then
        local scheduled_prefetch = scheduled.pending
            and scheduled.pending.options
            and scheduled.pending.options.prefetch == true
        if scheduled_prefetch then
            self:_cancelScheduledPrefetch(
                options.prefetch and "replaced" or "manual_download")
        else
            if not options.prefetch then
                self.show_transient(_("Another download is already in progress."), 1)
            end
            return false
        end
    end

    local active = self._active_job
    if active then
        if options.prefetch then
            if active.prefetch then
                self:cancelPrefetch("replaced")
                -- Don't overwrite a queued manual download with a new prefetch (M-L4 fix)
                if self._pending_start and not self._pending_start.options.prefetch then
                    self.show_transient(_("Another download is already in progress."), 1)
                    return false
                end
                self._pending_start = {
                    book = book,
                    chapters = chapters,
                    suffix = suffix,
                    options = options,
                }
                return true
            end
            return false
        end
        if active.prefetch then
            self:cancelPrefetch("manual_download")
            self._pending_start = {
                book = book,
                chapters = chapters,
                suffix = suffix,
                options = options,
            }
            return true
        end
        self.show_transient(_("Another download is already in progress."), 1)
        return false
    end

    local total = #chapters
    if total == 0 then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "no_chapters")
        end
        if not options.prefetch then
            self.show_info(_("No chapters to download."))
        end
        return false
    end

    -- v4.0 breakpoint resume: if an interrupted download exists for this
    -- book (same book/suffix/mode/chapter list), ask whether to continue
    -- instead of silently restarting from scratch.
    local mode = options.separate_chapters and "separate" or "book"
    local progress = self:_loadProgress(book, mode)
    if progress and not options.prefetch and not options.single_chapter then
        local book_id = tostring(book.book_id or book.bookId or "")
        local matches = tostring(progress.book_id or "") == book_id
            and progress.suffix == (suffix or "book")
            and progress.mode == mode
            and type(progress.chapters) == "table"
        if matches then
            local uids = {}
            for _, ch in ipairs(chapters) do
                table.insert(uids, tostring(ch.chapterUid or ch.chapterId or ""))
            end
            local saved = progress.chapters
            if #saved ~= #uids then
                matches = false
            else
                for i, uid in ipairs(uids) do
                    if saved[i] ~= uid then
                        matches = false
                        break
                    end
                end
            end
        end
        if matches then
            local done_count = 0
            for _uid, done in pairs(progress.done or {}) do
                if done then done_count = done_count + 1 end
            end
            local resume = progress
            UIManager:show(ConfirmBox:new{
                text = T(_("Incomplete download found (%1/%2 chapters done). Resume?"),
                    tostring(done_count), tostring(total)),
                ok_text = _("Resume"),
                ok_callback = function()
                    self:_startDownload(book, chapters, suffix, options, resume)
                end,
                cancel_text = _("Restart"),
                cancel_callback = function()
                    Content.clear_spool(self.settings, book)
                    self:_startDownload(book, chapters, suffix, options, nil)
                end,
            })
            return true
        end
        -- Mismatched progress (different mode/suffix or changed chapter list):
        -- do NOT wipe it here. The user may have switched download mode and
        -- still want to resume the other mode's progress later; a stale file
        -- is tiny and gets cleaned on the next successful download.
    end
    return self:_startDownload(book, chapters, suffix, options, nil)
end

-- Persist download progress to <cache>/.dl/progress[-separate].json so an
-- interrupted download can be resumed later. Skipped for prefetch and
-- single-chapter jobs (they are short-lived and must not clobber progress).
function Downloader:_saveProgress(dl)
    if dl.prefetch or dl.single_chapter then
        return
    end
    local mode = dl.separate_chapters and "separate" or "book"
    local progress = {
        version = 1,
        book_id = tostring(dl.book.book_id or dl.book.bookId or ""),
        suffix = dl.suffix,
        mode = mode,
        chapters = {},
        done = {},
        selected = {},
        failed = dl.failed or {},
        index = dl.index,
        footnotes_done = dl.footnotes_done == true,
        updated_at = os.time(),
    }
    for _, ch in ipairs(dl.chapters or {}) do
        table.insert(progress.chapters, tostring(ch.chapterUid or ch.chapterId or ""))
    end
    for uid, _path in pairs(dl.body_paths or {}) do
        progress.done[uid] = true
    end
    for _, ch in ipairs(dl.selected or {}) do
        table.insert(progress.selected, tostring(ch.chapterUid or ch.chapterId or ""))
    end
    local ok, encoded = pcall(function()
        return self.client:json_encode(progress)
    end)
    if not ok then
        logger.warn("progress encode failed:", log_error(encoded))
        return
    end
    local ok_write, err_write = pcall(function()
        local spool = Content.spool_dir(self.settings, dl.book)
        PluginUtil.mkdirs(spool)
        Content.write_file(Content.spool_progress_path(self.settings, dl.book, mode), encoded)
    end)
    if not ok_write then
        logger.warn("progress persist failed:", log_error(err_write))
    end
end

function Downloader:_loadProgress(book, mode)
    local path = Content.spool_progress_path(self.settings, book, mode)
    local encoded = Content.read_file(path)
    if not encoded then
        return nil
    end
    local ok, progress = pcall(function()
        return self.client:json_decode(encoded)
    end)
    if not ok or type(progress) ~= "table" then
        return nil
    end
    return progress
end

-- Shared download launch: builds the job state and starts the async state
-- machine. resume (optional) is a progress table that rebuilds finished
-- chapters from the spool and continues at the first chapter not on disk.
function Downloader:_startDownload(book, chapters, suffix, options, resume)
    local total = #chapters
    local dl = {
        book = book,
        chapters = chapters,
        suffix = suffix or "book",
        index = 1,
        cancelled = false,
        selected = {},
        bodies = {},
        body_paths = {},
        assets = {},
        assets_by_uid = {},
        state = {},
        total = total,
        failed = {},
        footnote_scans = {},
        footnote_stats = {
            candidates = 0,
            converted = 0,
            image_notes = 0,
            backlinks = 0,
            removed_note_blocks = 0,
            unresolved = 0,
            fallback = 0,
        },
        single_chapter = options.single_chapter == true,
        separate_chapters = options.separate_chapters == true,
        open_on_complete = options.open_on_complete == true,
        offer_read = options.offer_read ~= false,
        silent_completion = options.silent_completion == true,
        prefetch = options.prefetch == true,
        start_delay = tonumber(options.start_delay) or 0,
        on_start = options.on_start,
        on_complete = options.on_complete,
        started_at = time.now(),
    }
    if resume then
        -- v4.0 breakpoint resume: rebuild finished chapters from the spool.
        -- Bodies and asset metadata live on disk; only chapter objects and
        -- paths are reconstructed here. Footnote scans are re-run from the
        -- spooled bodies so the footnote pass works on the remaining chapters.
        local uid_to_chapter = {}
        for _i, ch in ipairs(chapters) do
            uid_to_chapter[tostring(ch.chapterUid or ch.chapterId or "")] = ch
        end
        local selected = {}
        local body_paths = {}
        local assets_by_uid = {}
        local failed = {}
        for _i, uid in ipairs(resume.selected or {}) do
            local ch = uid_to_chapter[uid]
            if ch then
                local body_path = Content.spool_body_path(self.settings, book, uid)
                if Content.read_file(body_path) then
                    table.insert(selected, ch)
                    body_paths[uid] = body_path
                    local meta_ok, meta = pcall(function()
                        return self.client:json_decode(
                            Content.read_file(Content.spool_assets_meta_path(self.settings, book, uid)) or "[]")
                    end)
                    if meta_ok and type(meta) == "table" then
                        assets_by_uid[uid] = meta
                    end
                end
            end
        end
        -- De-duplicate the resumed failed list (S5 fix): the snapshot already
        -- contains each uid once; if a chapter fails again after resume,
        -- _failChapter would append a duplicate, inflating the "N failed"
        -- count text. Seen-set keeps it unique.
        local seen_failed = {}
        for _i, uid in ipairs(resume.failed or {}) do
            if not seen_failed[uid] then
                seen_failed[uid] = true
                table.insert(failed, uid)
            end
        end
        -- Skip already-downloaded chapters: start at the first uid that is
        -- not present in the spool (or at the first failed chapter).
        local done_uids = {}
        for _i, ch in ipairs(selected) do
            done_uids[tostring(ch.chapterUid or ch.chapterId or "")] = true
        end
        local next_index = total + 1
        for i, ch in ipairs(chapters) do
            local uid = tostring(ch.chapterUid or ch.chapterId or "")
            if not done_uids[uid] then
                next_index = i
                break
            end
        end
        dl.selected = selected
        dl.body_paths = body_paths
        dl.assets_by_uid = assets_by_uid
        dl.failed = failed
        dl.index = next_index
        dl.footnotes_done = resume.footnotes_done == true
        -- Resume seeding (B1 fix): re-seed the cross-chapter asset-name
        -- tracker from the spooled asset metadata of already-downloaded
        -- chapters, so newly downloaded chapters never reuse an image name
        -- already claimed by an old chapter. Without this the resumed run
        -- starts from an empty used_asset_names and renumbers from img1,
        -- colliding with old chapters' hrefs in the aggregated EPUB.
        local used_asset_names = {}
        for _uid, meta in pairs(dl.assets_by_uid or {}) do
            for _j, asset in ipairs(meta or {}) do
                local base = tostring(asset.href or ""):match("([^/]+)$")
                if base and base ~= "" then
                    used_asset_names[base] = true
                end
            end
        end
        dl.state = dl.state or {}
        dl.state.used_asset_names = used_asset_names
        if not dl.footnotes_done then
            -- Re-scan footnotes for already-downloaded chapters so the
            -- footnote pass can transform them along with the new ones.
            for _i, ch in ipairs(selected) do
                local uid = tostring(ch.chapterUid or ch.chapterId or "")
                local body = Content.read_file(body_paths[uid])
                if body then
                    local scan_ok, scan = pcall(Footnotes.scan_chapter, body, ch)
                    if scan_ok then
                        dl.footnote_scans[uid] = scan
                    end
                end
            end
        end
        logger.info("download resumed:", "book_id=",
            tostring(book.book_id or book.bookId),
            "done=", tostring(#selected), "total=", tostring(total),
            "next_index=", tostring(next_index))
    end
    self._active_job = dl

    local task_label = options.single_chapter and _("Download chapter and read") or _("Download full book")
    local task_runner = options.prefetch and self.run_background_task
        or function(callback) return self.run_online_task(task_label, callback) end
    local function notifyStart()
        if dl.start_notified or type(dl.on_start) ~= "function" then return end
        dl.start_notified = true
        local called, start_err = pcall(dl.on_start)
        if not called then
            logger.warn("download start callback failed:", log_error(start_err))
        end
    end
    local function initializeDownload()
        if dl.cancelled then
            self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
            self:_finishJob(dl)
            return
        end
        local ok_init, err_init = pcall(function()
            Content.ensure_reader_state(self.client, book)
        end)
        if not ok_init then
            logger.err("initialize book download failed:", log_error(err_init))
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            if type(options.on_complete) == "function" then
                pcall(options.on_complete, false, err_init)
            end
            dl.completion_notified = true
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_("Download failed:\n%1"), display_error(err_init)))
            end
            return
        end

        self:_beginStandby()
        dl.standby_guard = true
        local init_ok, init_err = xpcall(function()
            notifyStart()
            if not dl.prefetch then self:_ensureProgressDialog(dl) end
        end, debug.traceback)
        if not init_ok then
            self:_releaseStandby(dl)
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            logger.err("download initialization failed:", log_error(init_err))
            self:_notifyCompletion(dl, false, init_err)
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_("Download failed:\n%1"), display_error(init_err)))
            end
            return
        end
        self:_scheduleGuarded(dl, function() self:_step(dl) end)
    end
    local started = task_runner(function()
        if dl.prefetch then
            -- Give the transient start notice enough event-loop time to paint
            -- and close before synchronous network work begins. Otherwise the
            -- request blocks the timeout callback and makes the notice look
            -- stuck while the whole UI appears frozen.
            notifyStart()
            UIManager:scheduleIn(math.max(0.1, dl.start_delay), initializeDownload)
        else
            initializeDownload()
        end
    end)
    if started == false then
        self:_notifyCompletion(dl, false, "offline")
        self:_finishJob(dl)
    end
    return started ~= false
end

function Downloader:_setStage(dl, title, progress)
    dl.stage_title = title
    dl.stage_progress = progress
    if not dl.progress_dialog then return end
    dl.progress_dialog:setTitle(title)
    if progress then
        dl.progress_dialog:reportProgress(progress)
    end
end

function Downloader:_perf(dl, stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info("download_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed),
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total), ...)
end

function Downloader:_failChapter(dl, err)
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    -- Retry each failed chapter once before giving up on it: transient
    -- network hiccups (weak K4 WiFi, CDN resets) are common and a single
    -- retry recovers most of them without hammering the server.
    dl.chapter_retries = dl.chapter_retries or {}
    if not dl.chapter_retries[uid] then
        dl.chapter_retries[uid] = true
        logger.warn("chapter download failed, retrying once:",
            "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
            "chapter_uid=", uid, "error=", log_error(err))
        dl.current = nil
        -- Keep dl.index unchanged so _step re-downloads this chapter.
        self:_scheduleGuarded(dl, function() self:_step(dl) end)
        return
    end
    table.insert(dl.failed, uid)
    if dl.footnote_scans then
        dl.footnote_scans[uid] = nil
    end
    logger.warn("chapter download failed after retry, skipping:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "error=", log_error(err))
    self:_saveProgress(dl)
    dl.current = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

local function add_footnote_stats(total, current)
    for _i, key in ipairs({
        "candidates", "converted", "image_notes", "backlinks",
        "removed_note_blocks", "unresolved",
    }) do
        total[key] = (tonumber(total[key]) or 0) + (tonumber(current and current[key]) or 0)
    end
end

function Downloader:_footnoteStep(dl)
    if dl.cancelled then
        self:_releaseStandby(dl)
        self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
        self:_finishJob(dl)
        if not dl.prefetch then
            self.show_transient(_("Download cancelled"), 2)
        end
        return
    end
    local job = dl.footnote_job
    if not job then
        dl.footnotes_done = true
        self:_scheduleGuarded(dl, function() self:_step(dl) end)
        return
    end
    if job.index > #dl.selected then
        dl.footnotes_done = true
        dl.footnote_job = nil
        if job.css_needed then
            dl.state.css = (dl.state.css or "") .. "\n"
                .. Footnotes.footnote_css_for(footnotes_mode)
        end
        self:_saveProgress(dl)
        logger.info("book footnotes processed:",
            "candidates=", tostring(dl.footnote_stats.candidates),
            "converted=", tostring(dl.footnote_stats.converted),
            "images=", tostring(dl.footnote_stats.image_notes),
            "backlinks=", tostring(dl.footnote_stats.backlinks),
            "removed_note_blocks=", tostring(dl.footnote_stats.removed_note_blocks),
            "unresolved=", tostring(dl.footnote_stats.unresolved),
            "fallback=", tostring(dl.footnote_stats.fallback))
        self:_scheduleGuarded(dl, function() self:_step(dl) end)
        return
    end

    local chapter = dl.selected[job.index]
    local uid = tostring(chapter.chapterUid or job.index)
    self:_setStage(dl,
        T(_("Processing footnotes · chapter %1/%2"),
            tostring(job.index), tostring(#dl.selected)), dl.total)
    -- v4.5: footnote display mode from download settings ("chapter"
    -- default; legacy/absent setting = chapter).
    local footnotes_mode = self.settings:get("cache").footnotes_mode
        == "page" and "page" or "chapter"
    -- v4.0: chapter bodies live on disk; read back one chapter at a time.
    local original = Content.read_file(dl.body_paths and dl.body_paths[uid]) or ""
    local started = time.now()
    local ok, transformed, stats = pcall(Footnotes.transform_chapter,
        original, dl.footnote_scans[uid], job.index_data, footnotes_mode)
    if ok then
        local valid, validation_error = Footnotes.validate(transformed)
        if valid then
            local write_ok, write_err = pcall(Content.write_file,
                dl.body_paths and dl.body_paths[uid], transformed)
            if not write_ok then
                dl.footnote_stats.fallback = dl.footnote_stats.fallback + 1
                logger.warn("footnote transform write-back failed; keeping original chapter:",
                    "chapter_uid=", uid, "error=", log_error(write_err))
            else
                add_footnote_stats(dl.footnote_stats, stats)
                if Footnotes.has_converted(stats) then job.css_needed = true end
            end
        else
            dl.footnote_stats.fallback = dl.footnote_stats.fallback + 1
            logger.warn("footnote transform validation failed; keeping original chapter:",
                "chapter_uid=", uid, "error=", log_error(validation_error))
        end
    else
        dl.footnote_stats.fallback = dl.footnote_stats.fallback + 1
        logger.warn("footnote transform failed; keeping original chapter:",
            "chapter_uid=", uid, "error=", log_error(transformed))
    end
    self:_perf(dl, "footnotes", started, "chapter_uid=", uid,
        "ok=", tostring(ok), "fallback=", tostring(not ok))
    job.index = job.index + 1
    self:_scheduleGuarded(dl, function() self:_footnoteStep(dl) end)
end

function Downloader:_startFootnotes(dl)
    dl.footnote_scans = dl.footnote_scans or {}
    dl.footnote_stats = dl.footnote_stats or {
        candidates = 0,
        converted = 0,
        image_notes = 0,
        backlinks = 0,
        removed_note_blocks = 0,
        unresolved = 0,
        fallback = 0,
    }
    local scans = {}
    for chapter_index, chapter in ipairs(dl.selected or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        if dl.footnote_scans[uid] then
            scans[uid] = dl.footnote_scans[uid]
        end
    end
    dl.footnote_job = {
        index = 1,
        index_data = Footnotes.build_book_index(scans, dl.selected),
        css_needed = false,
    }
    self:_scheduleGuarded(dl, function() self:_footnoteStep(dl) end)
end

function Downloader:_finishChapter(dl)
    if dl.cancelled or not dl.current then
        if dl.cancelled and dl.standby_guard then
            self:_releaseStandby(dl)
        end
        return
    end
    local chapter = dl.current.chapter
    local cache = self.settings:get("cache")
    local stage_text
    if cache.download_book_images then
        stage_text = T(_("Downloading images · chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    else
        stage_text = T(_("Processing chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    end
    self:_setStage(dl,
        stage_text, dl.index - 0.1)
    local started = time.now()
    local ok, xhtml, chapter_assets = pcall(function()
        return Content.finalize_single_chapter_content(
            self.client, self.settings, dl.book, chapter, dl.current.xhtml, dl.state
        )
    end)
    self:_perf(dl, "images_and_finalize", started, "ok=", tostring(ok))
    if not ok then
        self:_failChapter(dl, xhtml)
        return
    end
    local uid = tostring(chapter.chapterUid or dl.index)
    -- v4.0: spool the finalized chapter (XHTML + assets) to disk immediately
    -- instead of accumulating everything in RAM (256MB limit on K4).
    local body_path, assets_meta = Content.spool_chapter(
        self.settings, dl.book, uid, xhtml, chapter_assets or {})
    dl.body_paths = dl.body_paths or {}
    dl.body_paths[uid] = body_path
    dl.assets_by_uid = dl.assets_by_uid or {}
    dl.assets_by_uid[uid] = assets_meta or {}
    table.insert(dl.selected, chapter)
    -- Persist per-chapter asset metadata so a resume can rebuild the EPUB
    -- without re-downloading assets.
    local meta_ok, meta_err = pcall(function()
        local meta_path = Content.spool_assets_meta_path(self.settings, dl.book, uid)
        local encoded = self.client:json_encode(assets_meta or {})
        Content.write_file(meta_path, encoded)
    end)
    if not meta_ok then
        logger.warn("asset metadata persist failed:", "chapter_uid=", uid,
            "error=", log_error(meta_err))
    end
    -- v4.0: persist download progress for breakpoint resume.
    self:_saveProgress(dl)
    dl.current = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_step(dl)
    if dl.cancelled then
        self:_releaseStandby(dl)
        self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
        self:_finishJob(dl)
        if not dl.prefetch then
            self.show_transient(_("Download cancelled"), 2)
        end
        return
    end

    if dl.index > dl.total then
        if #dl.selected == 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            self:_releaseStandby(dl)
            logger.err("book download failed: no chapters downloaded")
            -- Only whole-book/separate jobs own the spool; prefetch and
            -- single-chapter jobs must not wipe a paused download's state.
            if not dl.prefetch and not dl.single_chapter then
                Content.clear_spool(self.settings, dl.book)
            end
            self:_notifyCompletion(dl, false, "no_chapters_downloaded")
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(_("No chapters were downloaded."))
            end
            return
        end
        if dl.footnote_scans and not dl.footnotes_done then
            self:_startFootnotes(dl)
            return
        end
        -- v4.0 resume: if the footnote pass already completed before the
        -- interruption, state.css was not spooled; re-fetch the book CSS and
        -- re-append the deterministic footnote stylesheet for the EPUB build.
        if dl.footnotes_done and not dl.state.css then
            pcall(function()
                local css = Content.fetch_chapter_css(
                    self.client, self.settings, dl.book, dl.selected[1])
                if css then
                    local footnotes_mode = self.settings:get("cache").footnotes_mode
                        == "page" and "page" or "chapter"
                    dl.state.css = css .. "\n"
                        .. Footnotes.footnote_css_for(footnotes_mode)
                end
            end)
        end
        self:_setStage(dl, _("Building EPUB..."), dl.total)
        local save_started = time.now()
        local ok, path, chapter_paths = pcall(function()
            -- v4.0: bodies/assets are spooled to disk; read back per chapter
            -- at aggregation time (single/separate) or stream from disk
            -- (whole-book) so RAM stays bounded on K4's 256MB.
            local function read_body(uid)
                return Content.read_file(dl.body_paths and dl.body_paths[uid]) or ""
            end
            -- Spooled asset metadata stores spool-relative paths; resolve to
            -- absolute paths for save_chapter_epub's read_file.
            local spool = Content.spool_dir(self.settings, dl.book)
            local function resolve_assets(uid)
                local resolved = {}
                for _i, asset in ipairs((dl.assets_by_uid and dl.assets_by_uid[uid]) or {}) do
                    table.insert(resolved, {
                        href = asset.href,
                        media_type = asset.media_type,
                        file = spool .. "/" .. asset.file,
                    })
                end
                return resolved
            end
            if dl.single_chapter then
                local chapter = dl.selected[1]
                local uid = tostring(chapter.chapterUid or 1)
                return Content.save_chapter_epub(
                    self.settings, dl.book, chapter, read_body(uid),
                    resolve_assets(uid),
                    dl.state.css
                )
            end
            if dl.separate_chapters then
                local paths = {}
                for chapter_index, chapter in ipairs(dl.selected) do
                    local uid = tostring(chapter.chapterUid or chapter_index)
                    paths[uid] = Content.save_chapter_epub(
                        self.settings, dl.book, chapter, read_body(uid),
                        resolve_assets(uid),
                        dl.state.css
                    )
                end
                return paths[tostring(dl.selected[1].chapterUid or 1)], paths
            end
            local cover_data
            local cover_url = WeRead.normalize_cover_url(dl.book.cover)
            if cover_url and cover_url ~= "" then
                pcall(function() cover_data = self.client:get_binary(cover_url) end)
            end
            return Content.save_book_epub_streamed(
                self.settings, dl.book, dl.selected, dl.body_paths,
                dl.assets_by_uid, dl.suffix, dl.state.css, cover_data
            )
        end)
        self:_perf(dl, "save_epub", save_started, "ok=", tostring(ok),
            "single=", tostring(dl.single_chapter))
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        self:_releaseStandby(dl)
        local books = self.settings:get("books", {})
        local book_id = dl.book.book_id or dl.book.bookId
        if book_id then
            local record = books[book_id]
            -- v4.5 fix: persist the downloaded chapter list back into the
            -- book record. A delete-and-redownload rebuilds the record
            -- without chapters, which breaks progress sync
            -- (capture_local -> catalog_unavailable).
            if type(dl.selected) == "table" and #dl.selected > 0 then
                dl.book.chapters = dl.selected
                if record then
                    record.chapters = dl.selected
                end
            end
            if not record then
                record = {}
                for key, value in pairs(dl.book) do record[key] = value end
            end
            local function apply_cache_result(target)
                target.cached_chapters = target.cached_chapters or {}
                if not ok then return end
                if dl.single_chapter then
                    local chapter = dl.selected[1]
                    target.cached_chapters[tostring(chapter.chapterUid or 1)] = path
                elseif dl.separate_chapters then
                    for chapter_index, chapter in ipairs(dl.selected) do
                        local uid = tostring(chapter.chapterUid or chapter_index)
                        target.cached_chapters[uid] = chapter_paths[uid]
                    end
                else
                    local previous_full = target.cached_full_book
                        or target.cached_file
                    for uid, cached_path in pairs(target.cached_chapters) do
                        if cached_path == previous_full or cached_path == path then
                            target.cached_chapters[uid] = nil
                        end
                    end
                    target.cached_full_book = path
                    -- v4.5: persist uid -> in-EPUB chapter file mapping so
                    -- chapter-list jumps can locate the selected chapter
                    -- inside the whole-book cache (text/chapter-NNN.xhtml,
                    -- numbered in dl.selected order by
                    -- save_book_epub_streamed).
                    local chapter_files = {}
                    for chapter_index, chapter in ipairs(dl.selected) do
                        local uid = tostring(chapter.chapterUid
                            or chapter.chapterId or chapter_index)
                        chapter_files[uid] = string.format(
                            "text/chapter-%03d.xhtml", chapter_index)
                    end
                    target.cached_chapter_files = chapter_files
                    -- Keep cached_file as a compatibility alias for existing
                    -- installs and cache-management code. Single/partial
                    -- downloads must never overwrite it.
                    target.cached_file = path
                end
            end

            apply_cache_result(dl.book)
            if record ~= dl.book then apply_cache_result(record) end
            record.cache_dir = dl.book.cache_dir or record.cache_dir
            record.reader_url = record.reader_url
                or dl.book.reader_url or WeRead.reader_url(book_id)
            dl.book.reader_url = dl.book.reader_url or record.reader_url
            books[book_id] = record
            self.settings:set("books", books)
            self.settings:flush()
        end
        self.refresh_shelf()
        if not ok then
            logger.err("save downloaded book failed:", log_error(path))
            self:_notifyCompletion(dl, false, path)
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_("Download failed:\n%1"), display_error(path)))
            end
            return
        end
        -- v4.0: download finished successfully; drop the spool now that
        -- everything is baked into the EPUB(s).
        --   whole-book: clear everything (bodies, assets, progress)
        --   separate-chapters: remove this run's chapter files and its own
        --     progress file (keeps any paused whole-book progress intact)
        --   single-chapter / prefetch: leave the spool alone. A single
        --     chapter is often part of a paused whole-book download; its
        --     spooled body/assets then feed the resume instead of being
        --     re-downloaded.
        if dl.prefetch or dl.single_chapter then
            -- keep spool
        elseif dl.separate_chapters then
            for _i, ch in ipairs(dl.selected) do
                Content.remove_spool_chapter(self.settings, dl.book,
                    tostring(ch.chapterUid or ch.chapterId or _i))
            end
            os.remove(Content.spool_progress_path(self.settings, dl.book, "separate"))
        else
            Content.clear_spool(self.settings, dl.book)
        end
        if #dl.failed > 0 then
            logger.warn(
                "book download completed with skipped chapters:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed)
            )
        else
            logger.info("book download completed:", "chapters=", tostring(#dl.selected))
        end
        local completion_text
        if #dl.failed > 0 then
            completion_text = T(
                _("Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"),
                tostring(#dl.selected), tostring(#dl.failed), path
            )
        else
            completion_text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#dl.selected), path)
        end
        if dl.footnote_stats and dl.footnote_stats.unresolved > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 footnote reference(s) could not be resolved and were kept as original links."),
                tostring(dl.footnote_stats.unresolved)
            )
        end
        if dl.footnote_stats and dl.footnote_stats.fallback > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 chapter(s) kept their original footnote markup after validation fallback."),
                tostring(dl.footnote_stats.fallback)
            )
        end
        self:_perf(dl, "download_total", dl.started_at,
            "success_chapters=", tostring(#dl.selected),
            "failed_chapters=", tostring(#dl.failed),
            "footnotes_converted=", tostring(dl.footnote_stats and dl.footnote_stats.converted or 0),
            "footnotes_unresolved=", tostring(dl.footnote_stats and dl.footnote_stats.unresolved or 0))
        if dl.open_on_complete then
            self:_notifyCompletion(dl, true, path)
            self:_finishJob(dl)
            local open_ok, open_err = pcall(self.open_file, path)
            if not open_ok then
                logger.warn("open_file failed after successful download:",
                    log_error(open_err))
            end
            return
        end
        self:_notifyCompletion(dl, true, path)
        self:_finishJob(dl)
        if dl.silent_completion then
            return
        end
        if not dl.offer_read then
            self.show_transient(
                T(_("Downloaded %1 chapters."), tostring(#dl.selected)), 2)
            return
        end
        UIManager:show(ConfirmBox:new{
            text = completion_text,
            ok_text = _("Read now"),
            ok_callback = self.safe_callback(_("Read now"), function()
                self.open_file(path)
            end),
            cancel_text = _("Close"),
        })
        return
    end

    local chapter = dl.chapters[dl.index]
    -- Resume (B2 fix): a chapter already spooled in a previous round (e.g. it
    -- sits after a failed-and-skipped chapter that created a gap) must not be
    -- re-downloaded from the network. Skip straight past it and advance, so a
    -- resumed run only fetches chapters that are actually missing.
    local resume_uid = tostring(chapter.chapterUid or dl.index)
    if dl.body_paths and dl.body_paths[resume_uid] then
        dl.index = dl.index + 1
        if dl.progress_dialog then
            dl.progress_dialog:reportProgress(dl.index - 1)
        end
        self:_scheduleGuarded(dl, function() self:_step(dl) end)
        return
    end
    self:_setStage(dl,
        T(_("Downloading chapter %1/%2: %3"), tostring(dl.index), tostring(dl.total),
            chapter.title or tostring(chapter.chapterUid)),
        dl.index - 1)
    local started = time.now()
    local ok, xhtml = pcall(function()
        return Content.fetch_single_chapter_source(
            self.client, self.settings, dl.book, chapter, dl.state
        )
    end)
    self:_perf(dl, "chapter_source", started, "ok=", tostring(ok))
    if not ok then
        self:_failChapter(dl, xhtml)
        return
    end
    local uid = tostring(chapter.chapterUid or dl.index)
    local scan_ok, scan = pcall(Footnotes.scan_chapter, xhtml, chapter)
    dl.footnote_scans = dl.footnote_scans or {}
    if scan_ok then
        dl.footnote_scans[uid] = scan
    else
        logger.warn("footnote scan failed; chapter will keep original footnote markup:",
            "chapter_uid=", uid, "error=", log_error(scan))
    end
    dl.current = { chapter = chapter, xhtml = xhtml }
    self:_finishChapter(dl)
end

return Downloader
