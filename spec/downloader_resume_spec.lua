-- Integration-style test for the v4.0 breakpoint resume (2026-09-29 audit
-- coverage gap: Downloader:start() had no spec exercising the interrupted
-- download path).
--
-- Scenario:
--   * a whole-book download of 3 chapters is cancelled right after chapter
--     2 is spooled (progress.json + spooled bodies on the "disk");
--   * re-issuing the same download must detect the matching progress, ask
--     "Resume?", and — on Resume — fetch ONLY the missing chapter 3 before
--     building the EPUB and clearing the spool.
--
-- The real Downloader state machine runs against an in-memory filesystem:
-- the real weread.lib.content module is loaded and only its file-I/O layer
-- (write_file/read_file/spool_*/clear_spool) is replaced by memfs stubs.
--
-- NOTE: busted runs all specs in ONE Lua state; stubs follow the
-- prefetch_guard_spec.lua pattern (preload + package.loaded, restore
-- pre-existing entries at teardown).
local __SPEC_STUB_NAMES = {
    "ui/widget/confirmbox", "device", "pluginshare", "ui/uimanager",
    "weread.lib.logger", "ui/time", "ffi/util", "bit",
    "weread.lib.crypto", "weread.lib.reader_state", "weread.lib.protocol",
    "weread.lib.book_store", "weread.lib.plugin_util",
    "weread.lib.i18n", "weread.lib.footnotes",
    "weread.lib.foreground_barrier", "weread.ui.download_dialog",
    "weread.lib.downloader", "weread.lib.content",
}
local __PREEXISTING = {}
for _, name in ipairs(__SPEC_STUB_NAMES) do
    __PREEXISTING[name] = { loaded = package.loaded[name], preload = package.preload[name] }
end
local function preload_stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = factory()
end

preload_stub("ui/widget/confirmbox", function()
    return { new = function(_class, opts) return opts end }
end)
preload_stub("device", function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end)
preload_stub("pluginshare", function() return {} end)
preload_stub("ui/uimanager", function()
    return {
        scheduleIn = function(_self, _delay, fn) fn() end,
        unschedule = function() end,
        close = function() end,
        show = function(_self, widget)
            _G.__SPEC_DIALOGS = _G.__SPEC_DIALOGS or {}
            _G.__SPEC_DIALOGS[#_G.__SPEC_DIALOGS + 1] = widget
        end,
        preventStandby = function() end,
        allowStandby = function() end,
        forceRePaint = function() end,
    }
end)
preload_stub("weread.lib.logger", function()
    return {
        info = function() end, warn = function() end, err = function() end,
        scoped = function() return { info = function() end, warn = function() end, err = function() end } end,
    }
end)
preload_stub("ui/time", function()
    local t = 1000000
    return { now = function() t = t + 1; return t end }
end)
preload_stub("ffi/util", function()
    return { template = function(text) return text end }
end)
preload_stub("bit", function() return {} end)
preload_stub("weread.lib.crypto", function() return {} end)
preload_stub("weread.lib.reader_state", function() return {} end)
preload_stub("weread.lib.protocol", function()
    return {
        urlencode = function(v) return tostring(v) end,
        reader_url = function() return "https://weread.qq.com/web/reader/x" end,
        is_mp_book = function(id) return tostring(id):sub(1, 7) == "MP_WXS_" end,
        normalize_cover_url = function(url) return url end,
    }
end)
preload_stub("weread.lib.footnotes", function()
    local function empty_stats()
        return {
            candidates = 0, converted = 0, image_notes = 0, backlinks = 0,
            removed_note_blocks = 0, unresolved = 0,
        }
    end
    return {
        scan_chapter = function()
            return { definitions = {}, refs = {}, anchors = {},
                definition_backlinks = {}, forward_ref_ids = {} }
        end,
        build_book_index = function() return {} end,
        transform_chapter = function(html) return html, empty_stats() end,
        validate = function() return true end,
        has_converted = function() return false end,
        footnote_css_for = function() return "" end,
    }
end)
preload_stub("weread.lib.foreground_barrier", function()
    return {
        active = function() return false end,
        max_defers = function() return 60 end,
        set = function() end,
        clear = function() end,
    }
end)
preload_stub("weread.ui.download_dialog", function()
    return {
        new = function()
            return {
                show = function() end, close = function() end,
                setTitle = function() end, reportProgress = function() end,
            }
        end,
    }
end)

local function __CLEAR()
    for name, saved in pairs(__PREEXISTING) do
        if saved.loaded ~= nil then
            package.loaded[name] = saved.loaded
        else
            package.loaded[name] = nil
        end
        if saved.preload ~= nil then
            package.preload[name] = saved.preload
        else
            package.preload[name] = nil
        end
    end
end

package.loaded["weread.lib.plugin_util"] = nil
package.loaded["weread.lib.book_store"] = nil
package.loaded["weread.lib.content"] = nil
package.loaded["weread.lib.downloader"] = nil
local Content = require("weread.lib.content")
local Downloader = require("weread.lib.downloader")

-- --------------------------------------------------------------------
-- In-memory filesystem + patched Content I/O layer
-- --------------------------------------------------------------------

local memfs = {}
local fetch_calls = 0
local cancel_after_uid = nil
local dl_ref = nil -- current Downloader instance (cancel hook target)

local function spool_body_path(uid)
    return "/mem/.dl/chapters/" .. tostring(uid) .. ".xhtml"
end
local function spool_assets_meta_path(uid)
    return "/mem/.dl/assets/" .. tostring(uid) .. ".json"
end

local function patch_content_for_memfs()
    -- Downloader calls these as module functions: Content.write_file(p, d).
    Content.write_file = function(path, data) memfs[path] = data end
    Content.read_file = function(path) return memfs[path] end
    Content.spool_dir = function(_settings, _book) return "/mem/.dl" end
    Content.spool_chapter = function(_settings, _book, uid, xhtml, assets)
        local body_path = spool_body_path(uid)
        memfs[body_path] = xhtml
        local meta = {}
        for i, asset in ipairs(assets or {}) do
            local file = "/mem/.dl/assets/" .. tostring(uid) .. "/" .. tostring(i)
            memfs[file] = asset.data
            meta[#meta + 1] = {
                href = asset.href, media_type = asset.media_type, file = file,
            }
        end
        -- Simulate the user pressing "Cancel download" right after this
        -- chapter is spooled: the flag lives on the JOB table (the state
        -- machine reads dl.cancelled), not on the Downloader instance.
        if cancel_after_uid and tostring(uid) == cancel_after_uid
            and dl_ref and dl_ref._active_job then
            dl_ref._active_job.cancelled = true
        end
        return body_path, meta
    end
    Content.clear_spool = function()
        for key in pairs(memfs) do memfs[key] = nil end
    end
    Content.remove_spool_chapter = function(_settings, _book, uid)
        memfs[spool_body_path(uid)] = nil
        memfs[spool_assets_meta_path(uid)] = nil
    end
    Content.ensure_reader_state = function() end
    Content.fetch_chapter_css = function() return nil end
    Content.finalize_single_chapter_content = function(_c, _s, _b, _ch, xhtml)
        return xhtml, {}
    end
    Content.fetch_single_chapter_source = function(_c, _s, _b, chapter)
        fetch_calls = fetch_calls + 1
        return "<body>" .. tostring(chapter.chapterUid) .. "</body>"
    end
    Content.save_book_epub_streamed = function()
        return "/mem/WeRead - book.epub"
    end
    Content.save_chapter_epub = function()
        return "/mem/WeRead - chapter.epub"
    end
end

-- --------------------------------------------------------------------
-- Doubles for the injected host callbacks
-- --------------------------------------------------------------------

local progress_store = {}
local progress_seq = 0

local function new_downloader(seed_books)
    local books_table = seed_books or {}
    local settings = {
        cache_dir = "/mem",
        get = function(_self, key, default)
            if key == "books" then return books_table end
            if key == "cache" then
                return {
                    download_book_images = false,
                    footnotes_mode = "chapter",
                    show_prefetch_notifications = true,
                }
            end
            return default
        end,
        set = function() end,
        -- real single-record write so tests can assert the persisted record
        set_book = function(_self, book_id, book)
            books_table[tostring(book_id)] = book
        end,
        remove_book = function() end,
        flush = function() end,
    }
    local client = {
        json_encode = function(_self, table)
            progress_seq = progress_seq + 1
            local tag = "PROGRESS-" .. tostring(progress_seq)
            progress_store[tag] = table
            return tag
        end,
        json_decode = function(_self, text)
            return progress_store[tostring(text)]
        end,
    }
    local dl = Downloader:new({
        client = client,
        settings = settings,
        show_info = function() end,
        show_transient = function() end,
        refresh_ui = function() end,
        refresh_shelf = function() end,
        open_file = function() end,
        safe_callback = function(_label, fn) return fn end,
        require_login = function() return true end,
        run_online_task = function(_label, fn) fn() return true end,
        run_background_task = function() return true end,
        is_connected = function() return true end,
    })
    return dl, books_table
end

local BOOK = { book_id = "B1", title = "Resume Book" }
local CHAPTERS = {
    { chapterUid = "u1", title = "C1" },
    { chapterUid = "u2", title = "C2" },
    { chapterUid = "u3", title = "C3" },
}

describe("Downloader breakpoint resume (v4.0)", function()
    teardown(__CLEAR)

    before_each(function()
        for key in pairs(memfs) do memfs[key] = nil end
        progress_store = {}
        progress_seq = 0
        fetch_calls = 0
        cancel_after_uid = nil
        dl_ref = nil
        _G.__SPEC_DIALOGS = nil
        patch_content_for_memfs()
    end)

    it("offers to resume a matching interrupted download", function()
        dl_ref = new_downloader()
        cancel_after_uid = "u2"
        local completed = {}
        local started = dl_ref:start(BOOK, CHAPTERS, "book", {
            on_complete = function(ok, value) completed = { ok, value } end,
        })
        assert.is_true(started)
        assert.is_false(completed[1])
        assert.equals("cancelled", completed[2])
        -- Chapters 1-2 are spooled; 3 was never fetched.
        assert.equals(2, fetch_calls)
        assert.is_not_nil(memfs[spool_body_path("u1")])
        assert.is_not_nil(memfs[spool_body_path("u2")])
        assert.is_nil(memfs[spool_body_path("u3")])
        -- progress.json persisted (2 done entries, matching chapter list).
        local progress = progress_store[memfs["/mem/.dl/progress.json"]]
        assert.is_table(progress)
        assert.equals("B1", progress.book_id)
        assert.equals(2, #progress.selected)
    end)

    it("resumes by fetching only the missing chapters", function()
        -- Arrange: run the interrupted download from the previous case.
        dl_ref = new_downloader()
        cancel_after_uid = "u2"
        dl_ref:start(BOOK, CHAPTERS, "book", { on_complete = function() end })
        local fetched_before = fetch_calls

        -- Act: re-issue the same download; the resume ConfirmBox appears.
        dl_ref = new_downloader()
        cancel_after_uid = nil
        local completed = {}
        local started = dl_ref:start(BOOK, CHAPTERS, "book", {
            on_complete = function(ok, value) completed = { ok, value } end,
        })
        assert.is_true(started)
        assert.is_nil(completed[1]) -- nothing ran yet: waiting on the dialog
        local dialogs = _G.__SPEC_DIALOGS or {}
        assert.equals(1, #dialogs)
        assert.is_not_nil(tostring(dialogs[1].text):find("Incomplete download found", 1, true))

        -- Confirm resume: only chapter 3 may hit the network.
        dialogs[1].ok_callback()
        assert.is_true(completed[1])
        assert.equals("/mem/WeRead - book.epub", completed[2])
        assert.equals(1, fetch_calls - fetched_before)
        -- Successful whole-book run cleared the spool.
        assert.is_nil(memfs[spool_body_path("u1")])
        assert.is_nil(next(memfs))
    end)

    it("starts from scratch when the user rejects the resume", function()
        dl_ref = new_downloader()
        cancel_after_uid = "u2"
        dl_ref:start(BOOK, CHAPTERS, "book", { on_complete = function() end })
        local fetched_before = fetch_calls

        dl_ref = new_downloader()
        cancel_after_uid = nil
        local completed = {}
        dl_ref:start(BOOK, CHAPTERS, "book", {
            on_complete = function(ok, value) completed = { ok, value } end,
        })
        local dialogs = _G.__SPEC_DIALOGS or {}
        assert.equals(1, #dialogs)
        dialogs[1].cancel_callback() -- "Restart": clear spool, full run
        assert.is_true(completed[1])
        assert.equals(3, fetch_calls - fetched_before)
        assert.is_nil(next(memfs))
    end)
end)


-- F-05 (2026-10-05 audit): session-shaped errors terminate the whole job
-- instead of "retry once then skip" for every remaining chapter (the 09/22
-- storm burned 26 chapters x 2 attempts of predictable failures and left
-- only a WARN line).
describe("Downloader session-error short-circuit (F-05)", function()
    teardown(__CLEAR)

    before_each(function()
        for key in pairs(memfs) do memfs[key] = nil end
        progress_store = {}
        progress_seq = 0
        fetch_calls = 0
        cancel_after_uid = nil
        dl_ref = nil
        _G.__SPEC_DIALOGS = nil
        patch_content_for_memfs()
    end)

    it("aborts the job on a session-shaped chapter error without retry", function()
        dl_ref = new_downloader()
        local real_fetch = Content.fetch_single_chapter_source
        Content.fetch_single_chapter_source = function(_c, _s, _b, chapter)
            fetch_calls = fetch_calls + 1
            error("plugins/.../content.lua: /web/book/chapter/e_0 returned empty object")
        end
        local completed = {}
        dl_ref:start(BOOK, CHAPTERS, "book", {
            on_complete = function(ok, value) completed = { ok, value } end,
        })
        -- one attempt only — no retry, no further chapters
        assert.equals(1, fetch_calls)
        assert.is_false(completed[1])
        assert.equals("authentication_required", completed[2])
        -- progress persisted so Resume keeps what landed
        assert.is_not_nil(memfs["/mem/.dl/progress.json"])
        Content.fetch_single_chapter_source = real_fetch
    end)

    it("still retries once with backoff on transient errors", function()
        dl_ref = new_downloader()
        local real_fetch = Content.fetch_single_chapter_source
        local attempts = 0
        Content.fetch_single_chapter_source = function(_c, _s, _b, chapter)
            fetch_calls = fetch_calls + 1
            attempts = attempts + 1
            if attempts == 1 then
                error("timeout")
            end
            return "<body>" .. tostring(chapter.chapterUid) .. "</body>"
        end
        local completed = {}
        dl_ref:start(BOOK, CHAPTERS, "book", {
            on_complete = function(ok, value) completed = { ok, value } end,
        })
        -- chapter 1: fail + retry (2 calls), chapters 2-3 succeed
        assert.equals(4, fetch_calls)
        assert.is_true(completed[1])
        Content.fetch_single_chapter_source = real_fetch
    end)
end)

-- F-18 (2026-10-05 audit): a completed download must never overwrite an
-- existing catalog with the downloaded subset — with a skipped chapter the
-- subset is smaller, and percent math + next-chapter prefetch use the full
-- catalog. Only a MISSING catalog gets filled (the v4.5 rebuild case).
describe("Downloader catalog preservation (F-18)", function()
    teardown(__CLEAR)

    before_each(function()
        for key in pairs(memfs) do memfs[key] = nil end
        progress_store = {}
        progress_seq = 0
        fetch_calls = 0
        cancel_after_uid = nil
        dl_ref = nil
        _G.__SPEC_DIALOGS = nil
        patch_content_for_memfs()
    end)

    it("keeps the full catalog when a whole-book run completes (F-18)", function()
        local full_chapters = {
            { chapterUid = "u1", title = "C1" },
            { chapterUid = "u2", title = "C2" },
            { chapterUid = "u3", title = "C3" },
        }
        local dl, books_table = new_downloader({
            B1 = { book_id = "B1", title = "Resume Book", chapters = full_chapters },
        })
        local completed = {}
        dl:start(BOOK, CHAPTERS, "book", {
            on_complete = function(ok, value) completed = { ok, value } end,
        })
        assert.is_true(completed[1])
        -- an existing catalog is never replaced by the downloaded subset
        assert.equals(3, #books_table.B1.chapters)
        assert.equals("u2", books_table.B1.chapters[2].chapterUid)
    end)

    -- B1 (upstream 6667f39 borrow): a whole-book run with failures must NOT
    -- publish a truncated EPUB nor clear the spool — the 09/22 storm lost 45
    -- chapters this way (published subset + wiped resume state).
    it("refuses to publish and keeps the spool when a chapter fails (B1)", function()
        local dl, books_table = new_downloader({
            B1 = { book_id = "B1", title = "Resume Book", chapters = {
                { chapterUid = "u1", title = "C1" },
                { chapterUid = "u2", title = "C2" },
                { chapterUid = "u3", title = "C3" },
            } },
        })
        Content.fetch_single_chapter_source = function(_c, _s, _b, chapter)
            fetch_calls = fetch_calls + 1
            if tostring(chapter.chapterUid) == "u2" then
                error("timeout") -- transient: retried once, then skipped
            end
            return "<body>" .. tostring(chapter.chapterUid) .. "</body>"
        end
        local completed = {}
        dl:start(BOOK, CHAPTERS, "book", {
            on_complete = function(ok, value) completed = { ok, value } end,
        })
        assert.is_false(completed[1])
        assert.equals("incomplete_full_book", completed[2])
        -- no EPUB published, spool + progress retained for Resume
        assert.is_nil(memfs["/mem/WeRead - book.epub"])
        assert.is_not_nil(memfs[spool_body_path("u1")])
        assert.is_not_nil(memfs[spool_body_path("u3")])
        assert.is_not_nil(memfs["/mem/.dl/progress.json"])
        assert.is_nil(books_table.B1.cached_full_book)
        Content.fetch_single_chapter_source = function(_c, _s, _b, chapter)
            fetch_calls = fetch_calls + 1
            return "<body>" .. tostring(chapter.chapterUid) .. "</body>"
        end
    end)

    it("still fills a missing catalog after delete-and-redownload (v4.5)", function()
        local dl, books_table = new_downloader()
        assert.is_nil(books_table.B1)
        local completed = {}
        dl:start(BOOK, CHAPTERS, "book", {
            on_complete = function(ok, value) completed = { ok, value } end,
        })
        assert.is_true(completed[1])
        -- record absent from the index: the completion path rebuilds it and
        -- set_book persists the downloaded chapter list (v4.5 contract)
        assert.equals(3, #books_table.B1.chapters)
    end)
end)
