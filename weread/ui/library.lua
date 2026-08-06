-- Bookshelf, book, chapter, public-account, and search UI flows.
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Content = require("weread.lib.content")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("weread.lib.logger")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists

local M = {}

-- Format a publish timestamp / date string as YYYY-MM-DD (book metadata only;
-- the book-reviews feature was removed from this K4 fork).
local function format_date(value)
    if type(value) == "string" then
        local year, month, day = value:match("(%d%d%d%d)[-/%.](%d%d?)[-/%.](%d%d?)")
        if year then
            return string.format("%s-%02d-%02d", year, tonumber(month), tonumber(day))
        end
        if not tonumber(value) then
            return value
        end
    end
    local timestamp = tonumber(value)
    if not timestamp or timestamp <= 0 then
        return ""
    end
    if timestamp > 100000000000 then
        timestamp = math.floor(timestamp / 1000)
    end
    return os.date("%Y-%m-%d", timestamp)
end

local function list_items_per_page()
    local perpage = 14
    if G_reader_settings and G_reader_settings.readSetting then
        perpage = tonumber(G_reader_settings:readSetting("items_per_page")) or perpage
    end
    return math.max(4, perpage)
end

function M:showBookshelf()
    if not self:requireLogin(true, true) then
        return
    end
    self:showBusy(_("Loading bookshelf..."))
    self:runOnlineTask(_("Bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:get_shelf()
        end)
        if not ok then
            self:closeBusy()
            logger.err("load bookshelf failed:", log_error(result))
            self:showInfo(T(
                _("Load bookshelf failed:\n%1\n\nIf other account features still work, use Search to find and download books."),
                display_error(result)
            ))
            return
        end
        local all_books = type(result) == "table"
            and type(result.books) == "table"
            and result.books
            or {}
        local shelf = self.settings:get("shelf")
        self.shelf_filters = { reading = shelf.filter_reading, download = shelf.filter_download }
        self.shelf_regular = {}
        self.shelf_mp = {}
        for _i, book in ipairs(all_books) do
            if WeRead.is_mp_book(book.bookId) then
                table.insert(self.shelf_mp, book)
            else
                table.insert(self.shelf_regular, book)
            end
        end
        self.shelf_books = self.shelf_regular
        self:closeBusy()
        if #self.shelf_mp > 0 then
            self:showShelfTabs()
        else
            self:showShelfPage()
        end
    end)
end

local function sortBooks(books, sort_order)
    if sort_order == "default" or not sort_order then
        return books
    end
    local sorted = {}
    for i, book in ipairs(books) do
        sorted[i] = book
    end
    if sort_order == "time_desc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) > (b.readUpdateTime or 0)
        end)
    elseif sort_order == "time_asc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) < (b.readUpdateTime or 0)
        end)
    elseif sort_order == "name_asc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_order == "name_desc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") > (b.title or "")
        end)
    end
    return sorted
end
M.sortBooks = sortBooks

function M:showShelfPage()
    local books = self.shelf_books or {}
    if #books == 0 then
        self:showInfo(_("Your WeRead shelf is empty."))
        return
    end
    local menu, buildItems
    local function refresh()
        menu:switchItemTable(nil, buildItems())
    end
    buildItems = function()
        local items = self:shelfToolbarItems(true, refresh)
        local sorted = sortBooks(books, self.settings:get("shelf").sort_order)
        local saved_books = self.settings:get("books", {})
        local downloaded_cache = {}
        self._shelf_saved_books = saved_books
        for _i, book in ipairs(sorted) do
            if self:bookMatchesFilters(book, saved_books, downloaded_cache) then
                local book_id = book.book_id or book.bookId
                local is_cached = self:isBookDownloaded(book, saved_books, downloaded_cache)
                local right_text
                if book.readUpdateTime and book.readUpdateTime > 0 then
                    right_text = os.date("%Y-%m-%d", book.readUpdateTime)
                elseif book.finishReading == 1 then
                    right_text = _("Done")
                else
                    right_text = ""
                end
                local function rightStatus(cached)
                    if cached then
                        return right_text ~= "" and "✓  " .. right_text or "✓"
                    end
                    return right_text
                end
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    mandatory = rightStatus(is_cached),
                    mandatory_func = function()
                        local current = self._shelf_saved_books and self._shelf_saved_books[book_id]
                        return rightStatus(self:bookRecordHasDownload(current))
                    end,
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        return items
    end
    menu = self:showList(_("WeRead Bookshelf"), buildItems(), _("Your WeRead shelf is empty."))
    self.shelf_menu = menu
    self._shelf_refresh = refresh
end

function M:refreshShelfCacheIndicators()
    self._shelf_saved_books = self.settings:get("books", {})
    if self.shelf_menu and self._shelf_refresh then
        local ok, err = pcall(self._shelf_refresh)
        if not ok then
            logger.warn("refresh shelf cache indicators failed:", log_error(err))
        end
    end
end

function M:showBookRecord(book)
    if not self:requireLogin(true, true) then
        return
    end
    local books = self.settings:get("books", {})
    local book_id = book.book_id or book.bookId
    if WeRead.is_mp_book(book_id) then
        self:showMPAccount(book)
        return
    end
    if book_id then
        books[book_id] = books[book_id] or {}
        books[book_id].book_id = book_id
        books[book_id].title = book.title
        books[book_id].author = book.author
        books[book_id].cover = book.cover
        books[book_id].updated_at = os.time()
        self.settings:set("books", books)
        self.settings:flush()
    end
    local saved = books[book_id] or book
    self:showBusy(_("Loading book info..."))
    self:runOnlineTask(_("Book info"), function()
        local ok, err = pcall(function()
            local info = self.client:get_book_info(book_id)
            if info then
                saved.intro = info.intro
                saved.publisher = info.publisher
                saved.isbn = info.isbn
                saved.wordCount = info.wordCount
                saved.newRating = info.newRating
                saved.newRatingCount = info.newRatingCount
                saved.translator = info.translator
                saved.categoryName = info.categoryName or info.category
                saved.publishTime = info.publishTime
                books[book_id] = saved
                self.settings:set("books", books)
                self.settings:flush()
            end
            local progress_result = self.client:get_progress(book_id)
            if progress_result and progress_result.book then
                saved.progress = progress_result.book.progress or 0
            end
        end)
        self:closeBusy()
        if not ok then
            logger.err("load book info failed:", log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), _("Book info"), display_error(err)))
            return
        end
        self:showBookMenu(saved)
    end)
end

function M:showBookMenu(book)
    local book_id = book.book_id or book.bookId
    if type(book.chapters) ~= "table" then
        Content.load_catalog_cache(self.client, self.settings, book)
    end
    local menu, buildItems
    local function refresh()
        if menu then
            menu:switchItemTable(nil, buildItems())
        end
    end

    buildItems = function()
        local items = {}

        if book.author and book.author ~= "" then
            table.insert(items, { text = _("Author"), mandatory = book.author })
        end
        if book.translator and book.translator ~= "" then
            table.insert(items, { text = _("Translator"), mandatory = book.translator })
        end
        if book.publisher and book.publisher ~= "" then
            table.insert(items, { text = _("Publisher"), mandatory = book.publisher })
        end
        local publish_date = format_date(book.publishTime)
        if publish_date ~= "" then
            table.insert(items, { text = _("Publication date"), mandatory = publish_date })
        end
        if book.categoryName and book.categoryName ~= "" then
            table.insert(items, { text = _("Category"), mandatory = book.categoryName })
        end
        if book.wordCount and book.wordCount > 0 then
            local wc = book.wordCount >= 10000
                and string.format("%.1f%s", book.wordCount / 10000, _("w words"))
                or tostring(book.wordCount)
            table.insert(items, { text = _("Word count"), mandatory = wc })
        end
        if book.isbn and book.isbn ~= "" then
            table.insert(items, { text = "ISBN", mandatory = book.isbn })
        end
        if book.intro and book.intro ~= "" then
            table.insert(items, {
                text = _("Introduction"),
                callback = function()
                    UIManager:show(InfoMessage:new{ text = book.intro })
                end,
            })
        end
        if book.newRating and book.newRating > 0 then
            local score = string.format("%.1f", book.newRating / 100)
            local count = book.newRatingCount and tostring(book.newRatingCount) or "0"
            table.insert(items, { text = _("Rating"), mandatory = T(_("%1 (%2 ratings)"), score, count) })
        end
        if book.progress and book.progress > 0 then
            table.insert(items, { text = _("Reading progress"), mandatory = tostring(book.progress) .. "%" })
        end
        if #items > 0 then
            items[#items].separator = true
        end

        local saved_books = self.settings:get("books", {})
        local saved = saved_books[book_id]
        local cached_path = self:getFullBookCachePath(saved or book)
        local is_cached = file_exists(cached_path)
        local has_cache = self:bookRecordHasDownload(saved or book)
        book.cached_full_book = is_cached and cached_path or nil

        table.insert(items, {
            text = _("Chapter list"),
            post_text = book.chapters and T(_("%1 chapters"), tostring(#book.chapters)) or _("Not loaded"),
            callback = self:safeCallback(_("Chapter list"), function()
                self:showChapterList(book)
            end),
        })
        if has_cache then
            table.insert(items, {
                text = _("Clear book cache"),
                callback = self:safeCallback(_("Clear book cache"), function()
                    self:confirmClearBookCache(book_id, book.title or book_id, function()
                        book.cached_file = nil
                        book.cached_full_book = nil
                        book.cached_chapters = nil
                        book.cache_dir = nil
                        book.chapters = nil
                        refresh()
                    end)
                end),
            })
        end
        table.insert(items, {
            text = _("Open cached book"),
            post_text = is_cached and _("Cached") or _("Not cached"),
            enabled_func = function() return is_cached end,
            callback = self:safeCallback(_("Open cached book"), function()
                self:openCachedBook(book)
            end),
        })
        table.insert(items, {
            text = _("Download full book"),
            post_text = _("EPUB"),
            callback = self:safeCallback(_("Download full book"), function()
                self:confirmDownloadAllChapters(book)
            end),
        })
        return items
    end

    menu = self:showList(book.title or _("Book details"), buildItems(), _("No actions."))
end

function M:showShelfTabs()
    local items = {
        {
            text = _("Books"),
            post_text = T(_("%1 books"), tostring(#self.shelf_regular)),
            callback = self:safeCallback(_("Books"), function()
                self.shelf_books = self.shelf_regular
                self:showShelfPage()
            end),
        },
        {
            text = _("Public Accounts"),
            post_text = T(_("%1 accounts"), tostring(#self.shelf_mp)),
            callback = self:safeCallback(_("Public Accounts"), function()
                self:showMPShelfPage()
            end),
        },
    }
    self:showList(_("WeRead Bookshelf"), items, _("Your WeRead shelf is empty."))
end

function M:showMPShelfPage()
    local books = self.shelf_mp or {}
    if #books == 0 then
        self:showInfo(_("No items."))
        return
    end
    local menu, buildItems
    local function refresh() menu:switchItemTable(nil, buildItems()) end
    buildItems = function()
        local items = self:shelfToolbarItems(false, refresh)
        local sorted = sortBooks(books, self.settings:get("shelf").sort_order)
        for _i, book in ipairs(sorted) do
            table.insert(items, {
                text = book.title or book.bookId or _("Untitled"),
                post_text = book.author or "",
                callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                    self:showMPAccount(book)
                end),
            })
        end
        return items
    end
    menu = self:showList(_("Public Accounts"), buildItems(), _("No items."))
end

function M:showMPAccount(book)
    self:rememberMPAccount(book)
    if not self:requireLogin(true, false) then
        return
    end
    local book_id = book.book_id or book.bookId
    local cached = self:getCachedMPArticles(book_id)
    if cached and #cached > 0 then
        self:showMPArticleList(book, cached)
        return
    end
    self:fetchMPArticles(book)
end

function M:rememberMPAccount(book)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return
    end
    local books = self.settings:get("books", {})
    local record = books[book_id] or {}
    record.book_id = book_id
    record.title = book.title or record.title
    record.author = book.author or record.author
    record.updated_at = os.time()
    -- Keep the resolved cache directory in sync both ways so the transient book
    -- object used for cached-path lookups knows where its articles actually live.
    record.cache_dir = book.cache_dir or record.cache_dir
    book.cache_dir = record.cache_dir
    books[book_id] = record
    self.settings:set("books", books)
    self.settings:flush()
end

function M:fetchMPArticles(book)
    if not self:requireLogin(true, false) then
        return
    end
    self:runOnlineTask(_("Loading articles..."), function()
        self:showBusy(_("Loading articles..."))
        local book_id = book.book_id or book.bookId
        local function request_articles()
            local ticket = self.settings:get("wr_ticket", "")
            if ticket == "" then ticket = nil end
            return self.client:get_mp_articles(book_id, 0, 100, ticket)
        end
        local ok, result, err_code = pcall(request_articles)
        if ok and not result and (err_code == -2041 or err_code == -2012) then
            logger.info("MP credentials rejected; renewing before retry")
            local renew_ok = pcall(function()
                return self.client:renew_cookie()
            end)
            if renew_ok then
                ok, result, err_code = pcall(request_articles)
            end
        end
        self:closeBusy()
        if not ok then
            logger.err("load MP articles failed:", log_error(result))
            self:showInfo(T(_("Load articles failed:\n%1"), display_error(result)))
            return
        end
        if not result and (err_code == -2041 or err_code == -2012) then
            logger.warn("load MP articles rejected, error_code:", tostring(err_code))
            self:showInfo(_("WeRead could not refresh the public-account credential. Please scan the QR code again."))
            return
        end
        if not result then
            logger.warn("load MP articles failed, error_code:", tostring(err_code))
            self:showInfo(T(_("Load articles failed:\n%1"), "errCode " .. tostring(err_code)))
            return
        end
        local articles = Content.parse_mp_articles(result)
        self:cacheMPArticles(book_id, articles)
        self:showMPArticleList(book, articles)
    end)
end

function M:getCachedMPArticles(book_id)
    local books = self.settings:get("books", {})
    local record = books[book_id]
    if record and record.mp_articles then
        return record.mp_articles
    end
    return nil
end

function M:cacheMPArticles(book_id, articles)
    local books = self.settings:get("books", {})
    books[book_id] = books[book_id] or {}
    books[book_id].mp_articles = articles
    books[book_id].mp_articles_time = os.time()
    self.settings:set("books", books)
    self.settings:flush()
end

function M:showMPArticleList(book, articles)
    local items = {}
    for _i, article in ipairs(articles) do
        local cached_path = Content.mp_article_cached_path(self.settings, book, article)
        local is_cached = cached_path ~= nil
        local date_str = ""
        if article.createTime and article.createTime > 0 then
            date_str = os.date("%Y-%m-%d", article.createTime)
        end
        table.insert(items, {
            text = article.title or _("Article"),
            post_text = date_str,
            mandatory = is_cached and _("Cached") or "",
            callback = self:safeCallback(article.title or _("Article"), function()
                if is_cached then
                    self:openFile(cached_path)
                else
                    self:downloadMPArticleAndRead(book, article)
                end
            end),
        })
    end
    table.insert(items, {
        text = _("Refresh article list"),
        callback = self:safeCallback(_("Refresh article list"), function()
            self:fetchMPArticles(book)
        end),
    })
    self:showList(book.title or _("Public Account"), items, _("No articles."))
end

function M:downloadMPArticleAndRead(book, article)
    if not self:requireLogin(true, false) then
        return
    end
    self:runOnlineTask(_("Download article and read"), function()
        self:showBusy(T(_("Downloading article: %1"), article.title or ""))
        local progress_dialog
        local ok, path_or_err = pcall(function()
            return Content.fetch_mp_article_html(self.client, self.settings, book, article, {
                progress = function(current, total)
                    if not progress_dialog then
                        self:closeBusy()
                        progress_dialog = ProgressbarDialog:new{
                            title = T(_("Downloading images: %1"), article.title or ""),
                            progress_max = total,
                        }
                        progress_dialog:show()
                        self:refreshUI()
                    end
                    progress_dialog:reportProgress(current)
                end,
            })
        end)
        if progress_dialog then
            progress_dialog:close()
        else
            self:closeBusy()
        end
        if not ok then
            logger.err("download MP article failed:", log_error(path_or_err))
            self:showInfo(T(_("Download failed:\n%1"), display_error(path_or_err)))
            return
        end
        logger.info(
            "MP article downloaded:",
            "images=", self.settings:get("cache").download_mp_images and "embedded" or "removed"
        )
        -- Persist the resolved cache directory (set by save_mp_article_html) so the
        -- article files can still be located after the download directory changes.
        local book_id = book.book_id or book.bookId
        if book_id and book.cache_dir then
            local books = self.settings:get("books", {})
            local record = books[book_id] or {}
            record.cache_dir = book.cache_dir
            books[book_id] = record
            self.settings:set("books", books)
            self.settings:flush()
        end
        self:openFile(path_or_err)
    end)
end

function M:loadChapters(book, callback, force_refresh)
    if not force_refresh then
        if book.chapters and #book.chapters > 0 then
            callback(book.chapters)
            return
        end
        local cached = Content.load_catalog_cache(self.client, self.settings, book)
        if cached then
            callback(cached)
            return
        end
    end
    if not self:requireLogin(true, false) then
        return
    end
    self:runOnlineTask(_("Loading chapter list..."), function()
        self:showBusy(_("Loading chapter list..."))
        local ok, chapters_or_err = pcall(function()
            Content.ensure_reader_state(self.client, book)
            return Content.fetch_catalog(self.client, book)
        end)
        self:closeBusy()
        if not ok then
            logger.err("load chapters failed:", log_error(chapters_or_err))
            self:showInfo(T(_("Load chapters failed:\n%1"), display_error(chapters_or_err)))
            return
        end
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters_or_err)
        if not cache_ok then
            logger.warn("save chapter catalog cache failed:", log_error(cache_err))
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        callback(chapters_or_err)
    end)
end

function M:showChapterList(book)
    local menu
    local function buildItems(chapters)
        local items = {}
        local perpage = list_items_per_page()
        local chapters_per_page = math.max(1, perpage - 2)
        local function appendActions()
            items[#items + 1] = {
                text = _("[Action] Refresh chapter list"),
                bold = true,
                callback = self:safeCallback(_("Refresh chapter list"), function()
                    self:loadChapters(book, function(refreshed_chapters)
                        if menu then
                            local refreshed_items = buildItems(refreshed_chapters)
                            menu:switchItemTable(nil, refreshed_items)
                        end
                        self:showTransientInfo(T(_("Chapter list refreshed: %1 chapters"),
                            tostring(#refreshed_chapters)), 2)
                    end, true)
                end),
            }
            items[#items + 1] = {
                text = _("[Action] Select chapters to download"),
                bold = true,
                separator = true,
                callback = self:safeCallback(_("Select chapters to download"), function()
                    self:showChapterDownloadSelection(book, chapters, function()
                        if menu then
                            local refreshed_items = buildItems(chapters)
                            menu:switchItemTable(nil, refreshed_items, -1)
                        end
                    end)
                end),
            }
        end

        if #chapters == 0 then appendActions() end
        for page_start = 1, #chapters, chapters_per_page do
            appendActions()
            local page_end = math.min(#chapters, page_start + chapters_per_page - 1)
            for chapter_index = page_start, page_end do
                local chapter = chapters[chapter_index]
                local chapter_uid = chapter.chapterUid or chapter.chapterId
                local cached = book.cached_chapters
                    and book.cached_chapters[tostring(chapter_uid)]
                if cached and not file_exists(cached) then
                    book.cached_chapters[tostring(chapter_uid)] = nil
                    cached = nil
                end
                items[#items + 1] = {
                    text = chapter.title or T(_("Chapter %1"), tostring(chapter_uid)),
                    mandatory = cached and _("Cached")
                        or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                    callback = self:safeCallback(chapter.title or _("Chapter"), function()
                        self:jumpToChapter(book, chapter)
                    end),
                }
            end
        end
        return items, perpage
    end
    self:loadChapters(book, function(chapters)
        local items, perpage = buildItems(chapters)
        menu = self:showList(book.title or _("Chapter list"), items,
            _("No chapters."), { items_per_page = perpage })
    end)
end

function M:showChapterDownloadSelection(book, chapters, on_downloaded)
    local selected = {}
    local menu
    local function selectedChapters()
        local result = {}
        for _i, chapter in ipairs(chapters) do
            local uid = tostring(chapter.chapterUid or chapter.chapterId or _i)
            if selected[uid] then
                result[#result + 1] = chapter
            end
        end
        return result
    end
    local function selectedCount()
        local count = 0
        for _uid in pairs(selected) do count = count + 1 end
        return count
    end

    local items = {}
    local perpage = list_items_per_page()
    local chapters_per_page = math.max(1, perpage - 1)
    local function appendDownloadAction()
        items[#items + 1] = {
            text_func = function()
                return T(_("[Download] Selected chapters (%1)"),
                    tostring(selectedCount()))
            end,
            bold = true,
            select_enabled_func = function() return selectedCount() > 0 end,
            separator = true,
            callback = self:safeCallback(_("Download selected chapters"), function()
                local targets = selectedChapters()
                if #targets == 0 then return end
                self:confirmAndDownloadChapters(book, targets, "chapters", {
                    separate_chapters = true,
                    offer_read = false,
                    on_complete = function(ok)
                        if not ok then return end
                        UIManager:scheduleIn(0.1, function()
                            if menu then UIManager:close(menu) end
                            if on_downloaded then on_downloaded() end
                        end)
                    end,
                })
            end),
        }
    end
    for page_start = 1, #chapters, chapters_per_page do
        appendDownloadAction()
        local page_end = math.min(#chapters, page_start + chapters_per_page - 1)
        for chapter_index = page_start, page_end do
            local chapter = chapters[chapter_index]
            local uid = tostring(chapter.chapterUid or chapter.chapterId or chapter_index)
            local cached = book.cached_chapters and book.cached_chapters[uid]
            local is_cached = file_exists(cached)
            items[#items + 1] = {
                text_func = function()
                    local marker = selected[uid] and "[✓] " or "[  ] "
                    return marker .. (chapter.title or T(_("Chapter %1"), uid))
                end,
                mandatory_func = function()
                    if selected[uid] then return _("Selected") end
                    return is_cached and _("Cached")
                        or T(_("%1 words"), tostring(chapter.wordCount or 0))
                end,
                callback = self:safeCallback(chapter.title or _("Chapter"), function()
                    if selected[uid] then
                        selected[uid] = nil
                    else
                        selected[uid] = true
                    end
                    if menu then menu:updateItems() end
                end),
            }
        end
    end
    menu = self:showList(_("Select chapters to download"), items,
        _("No chapters."), { items_per_page = perpage })
end

function M:openFile(path)
    if not path or path == "" then
        self:showInfo(_("No cached file."))
        return
    end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

function M:openCachedBook(book)
    self:openFile(self:getFullBookCachePath(book))
end

-- Open a chapter, preferring its cached file and falling back to a download.
function M:openChapter(book, chapter)
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local cached = book.cached_chapters and book.cached_chapters[tostring(chapter_uid)]
    if cached and file_exists(cached) then
        self:openFile(cached)
    elseif self.downloader:promotePrefetch(book, chapter) then
        -- The downloader promotes the background task to a visible progress
        -- dialog and opens the chapter as soon as the same task completes.
        return
    else
        self:downloadChapterAndRead(book, chapter)
    end
end

-- Jump to a chapter (chapter-list "jump" semantics): open the cached file if
-- present, otherwise download it and open automatically when done — no
-- confirmation dialog, unlike openChapter's download-and-read flow.
function M:jumpToChapter(book, chapter)
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local cached = book.cached_chapters and book.cached_chapters[tostring(chapter_uid)]
    if cached and file_exists(cached) then
        self:openFile(cached)
        return true
    end
    if self.downloader:promotePrefetch(book, chapter) then
        -- Already being prefetched: promote to a visible dialog; it will open
        -- automatically on completion.
        return true
    end
    self.downloader:start(book, { chapter }, "chapter", {
        single_chapter = true,
        open_on_complete = true,
        offer_read = false,
    })
    return true
end

-- Open a chapter selected by cloud-progress resolution. Unlike ordinary
-- chapter navigation, a missing target must be confirmed explicitly and then
-- opened automatically so ProgressSync can apply its pending in-chapter jump
-- in the next onReaderReady event.
function M:openProgressTargetChapter(book, chapter)
    if type(book) ~= "table" or type(chapter) ~= "table" then
        return false, "target_chapter_unavailable"
    end
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local cached = chapter_uid and book.cached_chapters
        and book.cached_chapters[tostring(chapter_uid)]
    if cached and file_exists(cached) then
        self:openFile(cached)
        return true
    end

    local title = chapter.title
        or T(_("Chapter %1"), tostring(chapter_uid or ""))
    local confirm
    confirm = ConfirmBox:new{
        text = T(_(
            "Cloud progress is in \"%1\", but this chapter has not been downloaded.\n\n"
            .. "Download and open it now?"
        ), title),
        ok_text = _("Download target chapter"),
        ok_callback = self:safeCallback(_("Download target chapter"), function()
            UIManager:close(confirm)
            self.downloader:start(book, { chapter }, "chapter", {
                single_chapter = true,
                open_on_complete = true,
                on_complete = function(ok, reason)
                    if not ok and self.progress_sync then
                        self.progress_sync:cancel_pending_jump(reason)
                    end
                end,
            })
        end),
        cancel_text = _("Cancel"),
        cancel_callback = function()
            if self.progress_sync then
                self.progress_sync:cancel_pending_jump(
                    "target_chapter_download_cancelled")
            end
        end,
    }
    UIManager:show(confirm)
    return true
end

function M:downloadChapterAndRead(book, chapter)
    self:confirmAndDownloadChapters(book, { chapter }, "chapter", {
        single_chapter = true,
    })
end

function M:confirmDownloadAllChapters(book)
    self:loadChapters(book, function(chapters)
        self:confirmAndDownloadChapters(book, chapters, "full", {
            confirmation_text = T(_("Download all %1 chapters as one EPUB?"), tostring(#chapters)),
        })
    end)
end

-- K4 fork: underlines/thoughts removed; downloads are text-only by default.
function M:confirmAndDownloadChapters(book, chapters, suffix, options)
    options = options or {}
    local text = options.confirmation_text
        or T(_("Download %1 selected chapter(s)?"), tostring(#chapters))
    if suffix == "full" then
        text = text .. "\n" .. _(
            "A book with many chapters may take a long time. Prefer single- or multi-chapter downloads when possible."
        )
    end

    local dialog
    local function start()
        UIManager:close(dialog)
        local job_options = {}
        for key, value in pairs(options) do job_options[key] = value end
        self.downloader:start(book, chapters, suffix, job_options)
    end
    dialog = ButtonDialog:new{
        title = text,
        buttons = {
            {{
                text = _("Download"),
                callback = self:safeCallback(_("Download"), function()
                    start()
                end),
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

function M:pullProgressWithUI(book_id)
    if not self:requireLogin(true, true) then
        return
    end
    self:runNetworkAction(_("Pull progress"), function()
        local result = self.client:get_progress(book_id)
        local progress = result and result.book and result.book.progress or 0
        return T(_("Remote progress: %1%"), tostring(progress))
    end)
end

function M:showSearch()
    if not self:requireLogin(true, true) then
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search WeRead"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Search"), function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchWithUI(keyword)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function M:searchWithUI(keyword)
    if not keyword or keyword == "" then
        return
    end
    self:runOnlineTask(_("Search"), function()
        local ok, result = pcall(function()
            return self.client:gateway("/store/search", {
                keyword = keyword,
                count = 10,
            })
        end)
        if not ok then
            logger.err("search failed:", log_error(result))
            self:showInfo(T(_("Search failed:\n%1"), display_error(result)))
            return
        end
        local items = {}
        for group_index, group in ipairs(result.results or {}) do
            for book_index, entry in ipairs(group.books or {}) do
                local book = entry.bookInfo or entry
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    mandatory = book.category or "",
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        self:showList(T(_("Search: %1"), keyword), items, _("No search results."))
    end)
end

function M:showPasteReaderURL()
    local dialog
    dialog = InputDialog:new{
        title = _("Paste WeRead reader URL"),
        input = "https://weread.qq.com/web/reader/",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Parse"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Parse"), function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        self:parseReaderURLWithUI(url)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function M:parseReaderURLWithUI(url)
    if not self:requireLogin(true, false) then
        return
    end
    self:runNetworkAction(_("Parse reader URL"), function()
        local html = self.client:get_text(url, { referer = url })
        local book_id = html:match([["bookId"%s*:%s*"([^"]+)"]]) or html:match([["bookId"%s*:%s*(%d+)]])
        local title = html:match([["title"%s*:%s*"([^"]+)"]]) or _("Unknown title")
        local psvts = html:match([["psvts"%s*:%s*"([^"]+)"]])
        local pclts = html:match([["pclts"%s*:%s*"([^"]+)"]])
        local token = html:match([["token"%s*:%s*"([^"]+)"]])
        if not book_id then
            return _("Reader HTML loaded, but bookId was not found.")
        end
        local books = self.settings:get("books", {})
        local record = books[book_id] or {}
        record.book_id = book_id
        record.title = title
        record.reader_url = url
        record.psvts = psvts
        record.pclts = pclts
        record.token = token
        record.updated_at = os.time()
        books[book_id] = record
        self.settings:set("books", books)
        self.settings:flush()
        return T(_("Reader URL parsed.\nBook: %1\nbookId: %2"), title, book_id)
    end)
end


function M:showCurrentBookDetails()
    if not self:requireLogin(true, true) then
        return
    end
    local book_id = self:detectWeReadBook()
    local book = book_id and self.settings:get("books", {})[book_id] or nil
    if not book then
        self:showInfo(_("The current document is not a WeRead cached book."))
        return
    end
    book.book_id = book.book_id or book_id
    self:showBookRecord(book)
end

return M
