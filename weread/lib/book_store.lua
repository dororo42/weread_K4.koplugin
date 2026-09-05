local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local PluginUtil = require("weread.lib.plugin_util")

local BookStore = {}

local reading_fields = {
    app_id = true,
    chapter_idx = true,
    chapter_offset = true,
    chapter_uid = true,
    last_local_position = true,
    last_pull_at = true,
    last_remote_position = true,
    last_sync_error = true,
    last_upload_at = true,
    last_uploaded_position = true,
    pclts = true,
    pending_upload_position = true,
    pending_upload_reason = true,
    progress = true,
    psvts = true,
    read_context_updated_at = true,
    read_session_entered_at = true,
    read_session_id = true,
    reader_url = true,
    summary = true,
    token = true,
    verified_at = true,
    verified_source = true,
}

local article_fields = {
    mp_articles = true,
    mp_articles_time = true,
}

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    return value ~= "" and value or "weread"
end

local function dirname(path)
    if type(path) == "string" then
        return path:match("^(.*)/[^/]+$")
    end
end

-- S-07 (2026-09-05): every path a book record contributes must resolve
-- inside the configured download root. A hand-edited or corrupted
-- weread.lua record (book.cache_dir / cached_file / cached_chapters) must
-- not redirect metadata reads/writes elsewhere on the filesystem; when the
-- root check fails, fall back to the safe per-book directory under the root.
local function is_inside_root(root, dir)
    if type(root) ~= "string" or root == "" or type(dir) ~= "string" or dir == "" then
        return false
    end
    local check = dir:gsub("/+$", "")
    return check == root or check:sub(1, #root + 1) == root .. "/"
end

function BookStore.resolved_dir(settings, book_id, book)
    local dir
    if type(book) == "table" and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        dir = book.cache_dir
    end
    if not dir then
        dir = type(book) == "table"
            and dirname(book.cached_full_book or book.cached_file) or nil
    end
    if not dir and type(book) == "table" and type(book.cached_chapters) == "table" then
        for _uid, path in pairs(book.cached_chapters) do
            dir = dirname(path)
            if dir then break end
        end
    end
    local root = tostring(settings and settings.cache_dir or ""):gsub("/+$", "")
    if dir and is_inside_root(root, dir) then
        return dir
    end
    return root .. "/" .. basename_safe(book_id)
end
local resolved_dir = BookStore.resolved_dir

local function encode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(value)
    end
    return json:encode(value)
end

local function decode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(value)
    end
    return json:decode(value)
end

local function read_json(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok, value = pcall(decode, content)
    return ok and type(value) == "table" and value or nil
end

local function write_json(path, value)
    local ok, content = pcall(encode, value)
    if not ok then return false, content end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then return false, err end
    local write_ok, write_err = file:write(content)
    -- H-3 fix: check close() return value. write() may succeed while the data
    -- sits in the buffer; close() is where the actual flush (and disk-full /
    -- IO errors) can fail. Without this check a truncated tmp file would be
    -- renamed over the real file, corrupting the book metadata store.
    local close_ok, close_err = file:close()
    if not write_ok then
        os.remove(tmp_path)
        return false, write_err
    end
    if not close_ok then
        os.remove(tmp_path)
        return false, close_err or "close failed"
    end
    local rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        return false, rename_err
    end
    return true
end

local function merge(target, source)
    for key, value in pairs(source or {}) do
        target[key] = value
    end
end

local function has_values(value)
    return next(value) ~= nil
end

function BookStore.load(settings, book_id, index)
    local book = {}
    -- A corrupted setting entry (e.g. a non-table book record left by an
    -- interrupted write) must never crash the reader: merge() iterates with
    -- pairs(), which raises on a non-table, and this path runs during
    -- document close via detect_book -> settings:get("books").
    if type(index) == "table" then
        merge(book, index)
    end
    local dir = resolved_dir(settings, book_id, index)
    merge(book, read_json(dir .. "/metadata.json"))
    merge(book, read_json(dir .. "/reading_state.json"))
    merge(book, read_json(dir .. "/articles.json"))
    book.book_id = book.book_id or book.bookId or tostring(book_id)
    book.cache_dir = dir
    return book
end

function BookStore.save(settings, book_id, book)
    book = type(book) == "table" and book or {}
    local dir = resolved_dir(settings, book_id, book)
    PluginUtil.mkdirs(dir)

    local metadata = { book_id = book.book_id or book.bookId or tostring(book_id) }
    local reading_state = {}
    local articles = {}
    for key, value in pairs(book) do
        if article_fields[key] then
            articles[key] = value
        elseif reading_fields[key] then
            reading_state[key] = value
        elseif key ~= "chapters" and key ~= "cache_dir" and key ~= "bookId" then
            metadata[key] = value
        end
    end

    local ok, err = write_json(dir .. "/metadata.json", metadata)
    if not ok then return false, err end
    if has_values(reading_state) then
        ok, err = write_json(dir .. "/reading_state.json", reading_state)
        if not ok then return false, err end
    else
        os.remove(dir .. "/reading_state.json")
    end
    if has_values(articles) then
        ok, err = write_json(dir .. "/articles.json", articles)
        if not ok then return false, err end
    else
        os.remove(dir .. "/articles.json")
    end
    return true, { cache_dir = dir }
end

function BookStore.is_minimal_index(books)
    for _book_id, record in pairs(books or {}) do
        if type(record) ~= "table" then return false end
        for key in pairs(record) do
            if key ~= "cache_dir" then return false end
        end
    end
    return true
end

return BookStore
