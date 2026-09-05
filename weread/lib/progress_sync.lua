local PositionMapper = require("weread.lib.position_mapper")

local logger = require("weread.lib.logger").scoped("ProgressSync")

local ProgressSync = {}
ProgressSync.__index = ProgressSync

local OPEN_DELAY_SECONDS = 0.6
local RESUME_RECHECK_SECONDS = 5 * 60
local BUSY_RETRY_SECONDS = 2
local BUSY_RETRY_LIMIT = 10
-- v4.5 (#130 port): automatic pulls retry when the link is not ready yet.
-- Kindle/K4 WiFi needs 3-10s after wake or document open while the automatic
-- pull fires 0.6s in; without a retry it fails silently and verified stays
-- false, which stalls reading-time reporting until the next manual sync.
local PULL_RETRY_DELAY_SECONDS = 15
local PULL_MAX_RETRIES = 3
local SAME_THRESHOLD_PERCENT = 2
local SOURCE_CONFLICT_THRESHOLD_PERCENT = 2
-- Coalescing window for settings:flush() from _persist. Short enough that a
-- crash loses at most one interval of progress state; long enough to avoid a
-- flash write per progress update.
local FLUSH_INTERVAL_SECONDS = 30

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

local function document_path(document)
    if not document then return nil end
    return document.file
        or (type(document.getFilePath) == "function" and document:getFilePath())
end

function ProgressSync:new(options)
    options = options or {}
    assert(options.settings, "progress sync settings are required")
    assert(options.client, "progress sync client is required")
    assert(options.scheduler, "progress sync scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")
    assert(type(options.get_book) == "function", "get_book callback is required")
    assert(type(options.get_chapters) == "function", "get_chapters callback is required")
    assert(type(options.get_file_context) == "function", "get_file_context callback is required")
    assert(type(options.run_online) == "function", "run_online callback is required")
    assert(type(options.read_report) ~= "nil", "read_report is required")
    assert(type(options.goto_fraction) == "function", "goto_fraction callback is required")
    assert(type(options.open_chapter) == "function", "open_chapter callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        scheduler = options.scheduler,
        read_report = options.read_report,
        get_document = options.get_document,
        get_footer = options.get_footer,
        detect_book = options.detect_book,
        get_book = options.get_book,
        get_chapters = options.get_chapters,
        get_file_context = options.get_file_context,
        run_online = options.run_online,
        goto_fraction = options.goto_fraction,
        open_chapter = options.open_chapter,
        is_online = options.is_online or function() return true end,
        on_choice = options.on_choice or function(context)
            context.keep_local()
        end,
        notify = options.notify or function() end,
        now = options.now or os.time,
        state = "idle",
        generation = 0,
        pull_retry_token = 0,
        dirty = false,
        verified = false,
        -- Coalesced settings flush: _persist marks dirty and schedules a
        -- single flush; critical points (close, suspend, manual sync) force
        -- it immediately. Avoids one weread.lua write per progress update.
        _flush_pending = false,
        _flush_scheduled = false,
    }
    return setmetatable(object, self)
end

function ProgressSync:_config()
    return self.settings:get("sync", {})
end

-- Merge progress updates into memory immediately (BookStore writes the per-book
-- JSON right away so readers see fresh data), but defer the LuaSettings flush
-- and coalesce multiple updates into one disk write.
function ProgressSync:_schedule_flush()
    self._flush_pending = true
    if self._flush_scheduled then return end
    self._flush_scheduled = true
    -- S-05 (2026-09-05): keep the closure reachable so on_close_document can
    -- unschedule it (previously an anonymous closure that pinned the
    -- instance for up to 30s after teardown).
    self._flush_fn = function()
        self._flush_scheduled = false
        self._flush_fn = nil
        self:_flush_now()
    end
    self.scheduler:scheduleIn(FLUSH_INTERVAL_SECONDS, self._flush_fn)
end

function ProgressSync:_flush_now()
    if not self._flush_pending then return end
    self._flush_pending = false
    local ok, err = pcall(function()
        self.settings:flush()
    end)
    if not ok then
        log("warn", "progress sync settings flush failed:", tostring(err))
        self._flush_pending = true -- retry on next flush
    end
end

function ProgressSync:_persist(book_id, patch)
    book_id = tostring(book_id or "")
    if book_id == "" or type(patch) ~= "table" then return false end
    local books = self.settings:get("books", {})
    local book = books[book_id] or { book_id = book_id }
    for key, value in pairs(patch) do
        if value == false then
            book[key] = nil
        else
            book[key] = copy(value)
        end
    end
    books[book_id] = book
    -- P0-1C (2026-08-26 翻页卡滞修复): single-record write instead of a
    -- full books-table rewrite (set("books") writes every book's JSONs).
    -- _schedule_flush() still coalesces the LuaSettings flush as before.
    self.settings:set_book(book_id, book)
    self:_schedule_flush()
    return true
end

function ProgressSync:_local_fraction()
    local document = self.get_document()
    if not document then return nil end

    local footer = self.get_footer and self.get_footer()
    local footer_value = footer and tonumber(footer.percent_finished)
    if footer_value then
        if footer_value > 1 then footer_value = footer_value / 100 end
        return math.max(0, math.min(1, footer_value))
    end

    local page
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = tonumber(value) end
    end
    if not page and type(document.getPageNumber) == "function" then
        local ok, value = pcall(document.getPageNumber, document)
        if ok then page = tonumber(value) end
    end
    local total
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then total = tonumber(value) end
    end
    if page and total and total > 0 then
        return math.max(0, math.min(1, page / total))
    end
    local current_pos = tonumber(document.current_pos)
    local doc_height = tonumber(document.info and document.info.doc_height)
        or tonumber(document.doc_height)
    if current_pos and doc_height and doc_height > 0 then
        return math.max(0, math.min(1, current_pos / doc_height))
    end
    return nil
end

function ProgressSync:capture_local()
    local book_id = self.detect_book()
    if not book_id or is_mp_book(book_id) then
        return nil, "document_not_weread"
    end
    book_id = tostring(book_id)
    local document = self.get_document()
    if not document then return nil, "document_unavailable" end
    local path = document_path(document)
    if not path then return nil, "document_unavailable" end
    local cached = self.document_context
    local book
    local chapters
    local current_chapter
    local is_full_book
    if cached and cached.book_id == book_id and cached.path == path then
        book = cached.book
        chapters = cached.chapters
        current_chapter = cached.current_chapter
        is_full_book = cached.is_full_book
    else
        book = self.get_book(book_id)
        if type(book) ~= "table" then return nil, "book_not_found" end
        chapters = self.get_chapters(book)
        if type(chapters) ~= "table" or #chapters == 0 then
            return nil, "catalog_unavailable"
        end
        local _index
        _index, current_chapter, is_full_book =
            self.get_file_context(book, path)
        self.document_context = {
            book_id = book_id,
            book = book,
            chapters = chapters,
            current_chapter = current_chapter,
            is_full_book = is_full_book == true,
            path = path,
        }
    end
    local fraction = self:_local_fraction()
    if fraction == nil then return nil, "position_unavailable" end
    local position, reason = PositionMapper.local_to_remote(
        chapters,
        fraction,
        {
            is_full_book = is_full_book == true,
            current_chapter_uid = current_chapter
                and (current_chapter.chapterUid or current_chapter.chapterId),
            summary = book.summary or book.title or "",
        }
    )
    if not position then return nil, reason end
    position.book_id = book_id
    position.captured_at = self.now()
    position.current_chapter_uid = current_chapter
        and (current_chapter.chapterUid or current_chapter.chapterId)
    position.is_full_book = is_full_book == true
    return position, nil, {
        book_id = book_id,
        book = book,
        chapters = chapters,
        current_chapter = current_chapter,
        is_full_book = is_full_book == true,
        path = path,
    }
end

function ProgressSync:_mark_verified(book_id, reason, local_position, remote)
    self.current_book_id = tostring(book_id)
    self.verified = true
    self.verified_at = self.now()
    self.verified_reason = reason
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    self.state = "verified"
    self:_persist(book_id, {
        verified_at = self.verified_at,
        verified_source = reason,
        last_local_position = local_position,
        last_remote_position = remote,
        last_sync_error = false,
    })
    log("info", "verified:",
        "book=", tostring(book_id),
        "reason=", tostring(reason),
        "local=", tostring(local_position and local_position.percent or "-"),
        "remote=", tostring(remote and remote.percent or "-"))
end

function ProgressSync:_clear_verified(reason)
    self.verified = false
    self.verified_at = nil
    self.verified_reason = reason
    if self.current_book_id then
        self:_persist(self.current_book_id, {
            verified_at = false,
            verified_source = reason or "cleared",
        })
    end
end

function ProgressSync:_fetch_remote(book_id, chapters)
    local gateway
    local web
    local gateway_error
    local web_error
    if self.settings:is_api_configured() then
        local ok, result = pcall(self.client.get_progress, self.client, book_id)
        if ok then
            gateway, gateway_error = PositionMapper.normalize_remote(
                result, book_id, "gateway", chapters)
        else
            gateway_error = tostring(result)
        end
    end
    if self.settings:is_cookie_configured() then
        local ok, result = pcall(
            self.client.get_web_progress, self.client, book_id)
        if ok then
            web, web_error = PositionMapper.normalize_remote(
                result, book_id, "web", chapters)
        else
            web_error = tostring(result)
        end
    end
    local selected = PositionMapper.choose_remote(
        web,
        gateway,
        SOURCE_CONFLICT_THRESHOLD_PERCENT
    )
    if not selected then
        return nil, gateway_error or web_error or "remote_unavailable"
    end
    return selected
end

function ProgressSync:_apply_remote(remote, context, options)
    options = options or {}
    local target, reason = PositionMapper.remote_to_local(
        context.chapters,
        remote,
        {
            is_full_book = context.is_full_book,
            current_chapter_uid = context.current_chapter
                and (context.current_chapter.chapterUid
                    or context.current_chapter.chapterId),
        }
    )
    if not target then return false, reason end

    if target.requires_chapter_open then
        self:_clear_verified("switching_chapter")
        self.dirty = false
        self.pending_jump = {
            book_id = context.book_id,
            chapter_uid = target.chapter
                and (target.chapter.chapterUid or target.chapter.chapterId),
            fraction = target.fraction,
            remote = copy(remote),
            notify = options.manual == true,
            created_at = self.now(),  -- M-L3 fix: for expiry check
        }
        self.state = "switching_chapter"
        local open_ok, opened, open_error = pcall(
            self.open_chapter, context.book, target.chapter)
        if not open_ok or opened == false then
            self.pending_jump = nil
            self.state = "error"
            return false, (open_ok and open_error or opened)
                or "target_chapter_unavailable"
        end
        return true
    end
    local ok, err = self.goto_fraction(target.fraction)
    if not ok then return false, err or "jump_failed" end
    self.dirty = false
    self:_mark_verified(
        context.book_id,
        "remote_selected",
        self.local_position,
        remote
    )
    if options.manual then
        self.notify("remote_applied", { position = remote })
    end
    local apply_generation = self.generation
    self.scheduler:scheduleIn(0.15, function()
        if apply_generation ~= self.generation then return end
        local position = self:capture_local()
        if position then
            self.local_position = position
            self.dirty = false
            self:_persist(context.book_id, {
                last_local_position = position,
            })
        end
    end)
    return true
end

function ProgressSync:_upload_snapshot(position, reason, show_result)
    if type(position) ~= "table" then return false end
    local upload_generation = self.generation
    local book_id = tostring(position.book_id or self.current_book_id or "")
    local upload_book_id = book_id
    if book_id == "" then return false end
    if self.uploading then
        -- Another upload is in flight; persist for later retry (M-L2 fix)
        self:_persist(book_id, {
            pending_upload_position = position,
            pending_upload_reason = reason or "upload_busy",
        })
        return false
    end
    self:_persist(book_id, {
        pending_upload_position = position,
        pending_upload_reason = reason or "unspecified",
    })
    if not self.is_online() then
        self.state = "offline"
        if show_result then self.notify("offline", {}) end
        return false
    end
    self.uploading = true
    self.state = "uploading"
    local attempts = 0
    local attempt
    attempt = function()
        attempts = attempts + 1
        -- Pre-check before retrying: generation/book/online may have changed
        -- during the busy wait interval (P2-B fix).
        if upload_generation ~= self.generation
            or tostring(self.detect_book() or "") ~= upload_book_id then
            self.uploading = false
            return
        end
        if not self.is_online() then
            self.uploading = false
            self.state = "offline"
            return
        end
        -- Async upload: spawn subprocess, get result via on_complete callback
        -- (scheme B fix: UI not blocked, result correctly delivered).
        local spawned, result = pcall(
            self.read_report.upload_position_async,
            self.read_report,
            book_id,
            copy(position),
            0,
            function(accepted, outcome)
                -- on_complete callback (runs in parent after subprocess finishes)
                if upload_generation ~= self.generation
                    or tostring(self.detect_book() or "") ~= upload_book_id then
                    self.uploading = false
                    return
                end
                self.uploading = false
                if accepted then
                    self.state = "verified"
                    self.dirty = false
                    self.last_uploaded_position = copy(position)
                    self:_persist(book_id, {
                        last_local_position = position,
                        last_uploaded_position = position,
                        last_upload_at = self.now(),
                        pending_upload_position = false,
                        pending_upload_reason = false,
                        last_sync_error = false,
                    })
                    log("info", "upload accepted:",
                        "book=", book_id,
                        "percent=", tostring(position.percent),
                        "reason=", tostring(reason))
                    if show_result then
                        self.notify("upload_success", { position = position })
                    end
                else
                    local error_message = type(outcome) == "table"
                        and outcome.error or tostring(outcome)
                    self.state = "error"
                    self:_persist(book_id, {
                        last_sync_error = tostring(error_message or "upload_failed"),
                    })
                    log("warn", "upload failed:", tostring(error_message))
                    if show_result then
                        self.notify("upload_failed", {
                            error = tostring(error_message or "upload_failed"),
                        })
                    end
                end
            end
        )
        if not spawned then
            -- pcall caught an error from upload_position_async
            self.uploading = false
            self.state = "error"
            self:_persist(book_id, {
                last_sync_error = tostring(result or "upload_failed"),
            })
            log("warn", "upload async call failed:", tostring(result))
            if show_result then
                self.notify("upload_failed", {
                    error = tostring(result or "upload_failed"),
                })
            end
            return
        end
        -- Check result: "async" means spawned (wait for callback),
        -- "busy" means tick job in progress (retry), otherwise inline completed
        if result == "async" then
            return  -- on_complete will handle the result
        end
        if type(result) == "table" and result.error_kind == "busy"
            and attempts < BUSY_RETRY_LIMIT then
            self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, attempt)
            return
        end
        -- Inline fallback: upload_position_async already called on_complete
        self.uploading = false
    end
    local started = self.run_online("progress_upload", attempt)
    if not started then
        self.uploading = false
        self.state = "offline"
    end
    return started == true
end

function ProgressSync:_keep_local(local_position, remote, options)
    options = options or {}
    self.dirty = not PositionMapper.same_position(local_position, remote)
    self:_mark_verified(
        local_position.book_id,
        "local_selected",
        local_position,
        remote
    )
    if options.upload_now then
        self:_upload_snapshot(local_position, options.reason, true)
    elseif options.manual then
        self.notify("local_kept", { position = local_position })
    end
end

function ProgressSync:_resolve(local_position, remote, context, options)
    options = options or {}
    self.local_position = copy(local_position)
    -- Invalidate any previous unresolved choice (M-L1 fix)
    self._choice_generation = (self._choice_generation or 0) + 1
    local current_choice_gen = self._choice_generation
    self.remote_position = copy(remote)
    local comparison = PositionMapper.compare(
        local_position,
        remote,
        SAME_THRESHOLD_PERCENT
    )

    if comparison == "same" and not remote.conflict then
        self.dirty = false
        self:_mark_verified(
            context.book_id,
            "positions_match",
            local_position,
            remote
        )
        if options.manual then
            self.notify("already_synced", { position = local_position })
        end
        return
    end

    local ask = self:_config().ask_on_conflict ~= false
    if remote.conflict or ask then
        self.state = "awaiting_choice"
        local choice_generation = self.generation
        local function choice_is_current()
            return choice_generation == self.generation
                and tostring(self.detect_book() or "") == context.book_id
                and current_choice_gen == self._choice_generation
        end
        self.on_choice({
            book_title = context.book.title or context.book_id,
            local_position = copy(local_position),
            remote_position = copy(remote),
            source_conflict = remote.conflict == true,
            use_remote = function()
                if not choice_is_current() then return end
                local ok, reason = self:_apply_remote(
                    remote, context, { manual = options.manual })
                if not ok then
                    self.state = "error"
                    self.notify("jump_failed", { error = reason })
                end
            end,
            keep_local = function()
                if not choice_is_current() then return end
                self:_keep_local(local_position, remote, {
                    manual = options.manual,
                    upload_now = true,
                    reason = "explicit_local_choice",
                })
            end,
        })
        return
    end

    if comparison == "remote_ahead" then
        local ok, reason = self:_apply_remote(
            remote, context, { manual = options.manual })
        if not ok then
            self.state = "error"
            self.notify("jump_failed", { error = reason })
        end
    else
        self:_keep_local(local_position, remote, {
            manual = options.manual,
            upload_now = options.manual == true,
            reason = "manual_sync",
        })
    end
end

-- v4.5 (#130 port): schedule a delayed retry for an automatic pull whose
-- link was not ready. Guards: generation (document switched), retry_token
-- (a newer pull superseded this one), verified/pulling (already synced or
-- in flight), awaiting_choice (conflict dialog open). Hard attempt cap so a
-- persistently offline device does not retry forever.
function ProgressSync:_schedule_pull_retry(options, retry_token)
    local attempt = (options.retry or 0) + 1
    if attempt > PULL_MAX_RETRIES then
        log("warn", "pull retries exhausted:",
            "book=", tostring(self.current_book_id))
        return false
    end
    local generation = self.generation
    self.scheduler:scheduleIn(PULL_RETRY_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        if retry_token ~= self.pull_retry_token then return end
        if self.verified or self.pulling then return end
        if self.state == "awaiting_choice" then return end
        self:_pull({
            manual = false,
            retry = attempt,
            retry_token = retry_token,
        })
    end)
    log("info", "pull retry scheduled:",
        "book=", tostring(self.current_book_id),
        "attempt=", tostring(attempt),
        "delay=", tostring(PULL_RETRY_DELAY_SECONDS))
    return true
end

function ProgressSync:_pull(options)
    options = options or {}
    if self.pulling then return false end
    -- v4.5 (#130 port): retry-token bookkeeping. A plain pull (no token)
    -- invalidates any pending retry; a tokened retry aborts if superseded.
    local retry_token = options.retry_token
    if retry_token == nil then
        self.pull_retry_token = self.pull_retry_token + 1
        retry_token = self.pull_retry_token
    elseif retry_token ~= self.pull_retry_token then
        return false
    end
    local local_position, reason, context = self:capture_local()
    if not local_position then
        -- v4.5 fix: after a delete-and-redownload the book record has no
        -- chapter list and the file catalog cache may be gone too. Refetch
        -- the catalog online once (loadChapters persists it everywhere),
        -- then retry the pull. No loop: the retry only happens after a
        -- successful catalog fetch.
        if reason == "catalog_unavailable"
            and not self._catalog_retrying
            and self.refresh_chapters
            and self.is_online() then
            self._catalog_retrying = true
            local book = context and self.get_book(context.book_id)
            if book then
                local ok, refresh_err = pcall(function()
                    self.refresh_chapters(book, function(chapters)
                        self._catalog_retrying = false
                        if type(chapters) == "table" and #chapters > 0 then
                            self:_pull(options)
                        elseif options.manual then
                            self.notify("local_unavailable",
                                { error = "catalog_unavailable" })
                        end
                    end)
                end)
                if not ok then
                    self._catalog_retrying = false
                    log("warn", "catalog recovery failed:", tostring(refresh_err))
                else
                    return true
                end
            else
                self._catalog_retrying = false
            end
        end
        if options.manual then self.notify("local_unavailable", { error = reason }) end
        return false
    end
    if not self.settings:is_api_configured()
        and not self.settings:is_cookie_configured() then
        if options.manual then self.notify("authentication_required", {}) end
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            -- v4.5 (#130 port): link not ready yet (fresh wake / document
            -- open); retry automatically instead of failing silently.
            self:_schedule_pull_retry(options, retry_token)
        end
        return false
    end

    local generation = self.generation
    self.pulling = true
    self.state = "pulling"
    local started = self.run_online("progress_pull", function()
        self.pulling = false
        local remote, pull_error = self:_fetch_remote(
            context.book_id,
            context.chapters
        )
        if generation ~= self.generation
            or tostring(self.detect_book() or "") ~= context.book_id then
            return
        end
        -- Re-capture local position if user turned pages during the pull (H-6 fix)
        local current_position = self:capture_local()
        if current_position and local_position
            and not PositionMapper.same_position(current_position, local_position) then
            -- Local position changed during pull; use the fresh one
            local_position = current_position
            self.local_position = copy(current_position)
        end
        if not remote then
            self.state = "error"
            self:_persist(context.book_id, {
                last_pull_at = self.now(),
                last_sync_error = tostring(pull_error),
            })
            if options.manual then
                self.notify("pull_failed", { error = tostring(pull_error) })
            end
            return
        end
        self:_persist(context.book_id, {
            last_remote_position = remote,
            last_local_position = local_position,
            last_pull_at = self.now(),
            last_sync_error = false,
        })
        self:_resolve(local_position, remote, context, options)
    end)
    if not started then
        self.pulling = false
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            -- v4.5 (#130 port): online task could not start; retry later.
            self:_schedule_pull_retry(options, retry_token)
        end
    end
    return started == true
end

function ProgressSync:_apply_pending_jump(book_id)
    local pending = self.pending_jump
    -- Expire stale pending jumps (M-L3 fix)
    if pending and pending.created_at
        and (self.now() - pending.created_at) > 5 * 60 then  -- 5 minutes
        self:cancel_pending_jump("expired")
        return false
    end
    if not pending or tostring(pending.book_id) ~= tostring(book_id) then
        return false
    end
    local local_position, _reason, context = self:capture_local()
    if not context or not context.current_chapter
        or tostring(context.current_chapter.chapterUid or context.current_chapter.chapterId)
            ~= tostring(pending.chapter_uid) then
        return false
    end
    self.pending_jump = nil
    local ok, err = self.goto_fraction(pending.fraction)
    if not ok then
        self.state = "error"
        self.notify("jump_failed", { error = err })
        return true
    end
    self.dirty = false
    self:_mark_verified(
        book_id,
        "remote_chapter_applied",
        local_position,
        pending.remote
    )
    if pending.notify then
        self.notify("remote_applied", { position = pending.remote })
    end
    local apply_generation = self.generation
    self.scheduler:scheduleIn(0.15, function()
        if apply_generation ~= self.generation then return end
        local position = self:capture_local()
        if position then
            self.local_position = position
            self:_persist(book_id, { last_local_position = position })
        end
    end)
    return true
end

function ProgressSync:cancel_pending_jump(reason)
    if not self.pending_jump then return false end
    self.pending_jump = nil
    self.dirty = false
    self.state = "unverified"
    self:_clear_verified(tostring(reason or "pending_jump_cancelled"))
    return true
end

function ProgressSync:on_reader_ready()
    self.generation = self.generation + 1
    -- Reset stale pulling/uploading flags from crashed pulls (H-5 fix)
    self.pulling = false
    self.uploading = false
    local generation = self.generation
    self.current_book_id = nil
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.verified = false
    self.dirty = false
    self.state = "waiting"

    self.scheduler:scheduleIn(OPEN_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        -- v4.5 R1: the whole flow is a local function so that a successful
        -- online catalog recovery can re-run it (delete-and-redownload
        -- rebuilds the book record without chapters).
        local function ready_flow()
            if generation ~= self.generation then return end
            local book_id = self.detect_book()
            if not book_id or is_mp_book(book_id) then
                self.state = "unsupported"
                return
            end
            book_id = tostring(book_id)
            self.current_book_id = book_id
            if self:_apply_pending_jump(book_id) then return end

            -- Check for pending offline upload backlog
            local book = self.get_book(book_id)
            if book and book.pending_upload_position then
                local pending = book.pending_upload_position
                -- Only retry if we're now online
                if self.is_online() then
                    self:_upload_snapshot(pending, "offline_backlog", false)
                end
            end

            local local_position, reason = self:capture_local()
            if not local_position then
                -- v4.5 R1: same online recovery as _pull: refetch the
                -- catalog once, then re-run this flow. No loop: recovery
                -- only re-runs after a successful (non-empty) fetch.
                if reason == "catalog_unavailable"
                    and not self._catalog_retrying
                    and self.refresh_chapters
                    and self.is_online() then
                    self._catalog_retrying = true
                    local recovery_book = self.get_book(book_id)
                    if recovery_book then
                        local ok, refresh_err = pcall(function()
                            self.refresh_chapters(recovery_book, function(chapters)
                                self._catalog_retrying = false
                                if type(chapters) == "table" and #chapters > 0 then
                                    ready_flow()
                                else
                                    self.state = "unsafe"
                                end
                            end)
                        end)
                        if not ok then
                            self._catalog_retrying = false
                            log("warn", "catalog recovery failed:",
                                tostring(refresh_err))
                            self.state = "unsafe"
                        end
                        return
                    end
                    self._catalog_retrying = false
                end
                self.state = "unsafe"
                log("warn", "local position unavailable:", tostring(reason))
                return
            end
            self.local_position = local_position
            self:_persist(book_id, { last_local_position = local_position })
            if self:_config().pull_on_open ~= true then
                self.state = "unverified"
                return
            end
            self:_pull({ manual = false })
        end
        ready_flow()
    end)
end

function ProgressSync:on_page_update()
    if not self.current_book_id then return end
    local position = self:capture_local()
    if not position then return end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
end

function ProgressSync:on_close_document()
    local position = self:capture_local() or self.local_position
    if position and self.verified
        and self:_config().upload_on_close == true then
        if not self.local_position
            or not PositionMapper.same_position(position, self.local_position) then
            self.dirty = true
        end
        if self.dirty then
            self:_upload_snapshot(position, "document_close", false)
        end
    end
    self.generation = self.generation + 1
    self.current_book_id = nil
    self.verified = false
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    -- Persist any pending progress state (e.g. an offline upload backlog)
    -- before the reader tears down.
    self:_flush_now()
    -- S-05 (2026-09-05): unschedule the coalesced flush — the forced
    -- _flush_now() above already persisted everything pending, and the
    -- leftover timer used to pin this instance for up to 30s.
    if self._flush_fn then
        self.scheduler:unschedule(self._flush_fn)
        self._flush_fn = nil
        self._flush_scheduled = false
    end
end

function ProgressSync:on_suspend()
    self.suspended_at = self.now()
    local position = self:capture_local() or self.local_position
    if position and self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    if position and self.verified and self.dirty
        and self:_config().upload_on_close == true then
        self:_upload_snapshot(position, "suspend", false)
    end
    self:_flush_now()
end

function ProgressSync:on_resume()
    local slept = self.suspended_at and self.now() - self.suspended_at or 0
    self.suspended_at = nil
    if slept >= RESUME_RECHECK_SECONDS
        and self:_config().pull_on_open == true then
        self:_clear_verified("resume_recheck")
        if self.current_book_id then
            local book = self.get_book(self.current_book_id)
            if book and book.pending_upload_position and self.is_online() then
                self:_upload_snapshot(book.pending_upload_position, "resume_backlog", false)
            end
        end
        self:_pull({ manual = false })
    end
end

function ProgressSync:sync_now()
    self:_flush_now()
    return self:_pull({ manual = true })
end

function ProgressSync:position_for_report(book_id)
    local current = self.detect_book()
    if not current or tostring(current) ~= tostring(book_id)
        or is_mp_book(book_id) then
        return nil, nil, false
    end
    if not self.verified then
        return nil, "progress_unverified", true
    end
    local position, reason = self:capture_local()
    if not position then
        return nil, reason or "position_unavailable", true
    end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
    return position, nil, true
end

function ProgressSync:status()
    return {
        state = self.state,
        book_id = self.current_book_id,
        verified = self.verified,
        dirty = self.dirty,
        pulling = self.pulling == true,
        uploading = self.uploading == true,
        local_position = copy(self.local_position),
        remote_position = copy(self.remote_position),
    }
end

return ProgressSync
