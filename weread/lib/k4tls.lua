-- k4tls 的 LuaJIT FFI 绑定；成功 (1, code, headers)，失败 (nil, err)。

local M = {
    _NAME = "weread.lib.k4tls",
    backend = "luasec",
    -- 库句柄（测试注入点）：非空时跳过 ffi.load
    _lib = nil,
    _loaded = false,
}

-- ---------------------------------------------------------------------------
-- 纯函数：错误码 → luasocket 语义文本（client.lua 重试分类的词表见
-- plugin_util.TRANSIENT_TRANSPORT_PATTERNS 与 ipv4_dns.RESOLUTION_ERROR_PATTERNS）
--
-- -18/-19 是确定性参数错误：文本刻意不含任何词表关键词，也不拼接 detail
-- （detail 可能含调用方传入的 URL/请求头），否则会被误判为可重试故障。
-- ---------------------------------------------------------------------------

local ERR_TEXT = {
    [-10] = "host or service not provided (k4tls dns)",
    [-11] = "connection refused (k4tls connect)",
    [-12] = "tls handshake failed (k4tls)",
    [-13] = "timeout (k4tls)",
    [-14] = "closed (k4tls write)",
    [-15] = "closed (k4tls read)",
    [-17] = "certificate verify failed (k4tls)",
    [-18] = "k4tls invalid or unsupported url",
    [-19] = "k4tls invalid request",
    [-99] = "k4tls internal error",
}

function M.error_text(status, detail)
    if not status then return "k4tls nil status" end
    local base = ERR_TEXT[status]
    if not base then
        return string.format("k4tls unknown error %d", status)
    end
    if status ~= -18 and status ~= -19 and detail and detail ~= "" then
        return base .. ": " .. tostring(detail)
    end
    return base
end

-- headers 表 → C ABI 的 "Name: value" 数组；丢弃传输层专属键
-- （Host/Content-Length/Connection/Transfer-Encoding 由 Rust 端统一负责）。
-- 返回 (list_of_strings, count)；list 元素顺序稳定（按键排序，测试可复现）。
function M.headers_table_to_list(headers)
    local names = {}
    for name, value in pairs(headers or {}) do
        if type(name) == "string" and type(value) == "string" then
            local lname = name:lower()
            if lname ~= "host" and lname ~= "content-length"
                and lname ~= "connection" and lname ~= "transfer-encoding" then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    local list = {}
    for i, name in ipairs(names) do
        list[i] = name .. ": " .. headers[name]
    end
    return list, #names
end

-- "Name: value\r\n..." blob → luasocket 风格 headers 表（原名键；同名后者胜）。
function M.headers_blob_to_table(blob)
    local t = {}
    if not blob or blob == "" then return t end
    local line = blob:gmatch("([^\r\n]+)")
    for h in line do
        local name, value = h:match("^([^:]+):%s*(.*)$")
        if name and #name > 0 then
            t[name] = value
        end
    end
    return t
end

-- ltn12 source（或 nil）→ body 字符串
function M.source_to_body(source)
    if not source then return nil end
    local chunks = {}
    while true do
        local chunk, err = source()
        if err then return nil, err end
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    return table.concat(chunks)
end

-- ---------------------------------------------------------------------------
-- FFI 绑定
-- ---------------------------------------------------------------------------

local function cdef(ffi)
    ffi.cdef[[
    typedef struct {
        const char *url;
        const char *method;
        const char *const *headers;
        int nheaders;
        const unsigned char *body;
        size_t body_len;
        int block_timeout_ms;
        int total_timeout_ms;
        size_t max_response_bytes;
        const unsigned char *trust_pem;
        size_t trust_pem_len;
    } k4tls_request_t;

    typedef struct {
        int status;
        char *headers_blob;
        size_t header_count;
        unsigned char *body;
        size_t body_len;
        char err[256];
    } k4tls_response_t;

    int k4tls_perform(const k4tls_request_t *req, k4tls_response_t *out);
    void k4tls_free_response(k4tls_response_t *out);
    const char *k4tls_version(void);
    ]]
end

-- 尝试加载 libk4tls.so；成功返回句柄，失败返回 nil + 原因。
-- 搜索路径：模块同目录（KOReader plugin 包内）→ ffi.load 默认路径。
function M._load(ffi)
    if M._lib then return M._lib end
    local search = { "k4tls" }
    local src = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(.*)/[^/]+$")
    if dir then
        search[#search + 1] = dir .. "/libk4tls.so"
    end
    for _, name in ipairs(search) do
        local ok, handle = pcall(ffi.load, name)
        if ok and handle then
            cdef(ffi)
            return handle
        end
    end
    return nil, "libk4tls.so not loadable"
end

function M.is_available()
    if M._loaded then return M._lib ~= nil end
    local ok, ffi = pcall(require, "ffi")
    if not ok or not ffi then return false end
    local lib = M._load(ffi)
    M._loaded = true
    M._lib = lib
    return lib ~= nil
end

function M.version()
    if not M.is_available() then return nil end
    local ffi = require("ffi")
    return ffi.string(M._lib.k4tls_version())
end

function M.request(req_opts)
    if not M.is_available() then
        return nil, "k4tls unavailable"
    end
    local ffi = require("ffi")
    local lib = M._lib

    local url = req_opts.url
    if type(url) ~= "string" or url:sub(1, 8) ~= "https://" then
        return nil, "k4tls: non-https url rejected"
    end
    local method = req_opts.method or "GET"
    local header_list, nheaders = M.headers_table_to_list(req_opts.headers)
    local body, source_err = M.source_to_body(req_opts.source)
    if source_err then return nil, source_err end

    local block_ms = tonumber(req_opts.block_timeout) or 8
    local total_ms = tonumber(req_opts.total_timeout) or block_ms * 2
    local max_bytes = tonumber(req_opts.transport_max_bytes) or 8 * 1024 * 1024

    local c_url = ffi.new("char[?]", #url + 1, url)
    local c_method = ffi.new("char[?]", #method + 1, method)
    local c_headers = ffi.new("const char*[?]", math.max(nheaders, 1))
    local c_header_strings = {}
    for i, h in ipairs(header_list) do
        c_header_strings[i] = ffi.new("char[?]", #h + 1, h)
        c_headers[i - 1] = c_header_strings[i]
    end
    local c_body = nil
    if body and #body > 0 then
        c_body = ffi.new("unsigned char[?]", #body, body)
    end

    local req = ffi.new("k4tls_request_t")
    req.url = c_url
    req.method = c_method
    req.headers = c_headers
    req.nheaders = nheaders
    req.body = c_body
    req.body_len = c_body and #body or 0
    req.block_timeout_ms = math.floor(block_ms * 1000)
    req.total_timeout_ms = math.floor(total_ms * 1000)
    req.max_response_bytes = max_bytes
    req.trust_pem = nil
    req.trust_pem_len = 0

    local resp = ffi.new("k4tls_response_t")
    local rc = lib.k4tls_perform(req, resp)
    if rc ~= 0 then
        local err = ffi.string(resp.err)
        return nil, "k4tls perform rc=" .. tostring(rc) .. (err ~= "" and (": " .. err) or "")
    end

    ffi.gc(resp, lib.k4tls_free_response)
    local copied, status, body_data, blob, err = pcall(function()
        local body_len = tonumber(resp.body_len)
        local data, headers_blob
        if resp.body ~= nil and body_len > 0 then
            data = ffi.string(resp.body, body_len)
        end
        if resp.headers_blob ~= nil then
            headers_blob = ffi.string(resp.headers_blob)
        end
        return tonumber(resp.status), data, headers_blob, ffi.string(resp.err)
    end)
    lib.k4tls_free_response(resp)
    ffi.gc(resp, nil)
    if not copied then error(status, 0) end

    if status < 0 then
        if status == -16 then
            return nil, "binary response exceeds the " .. tostring(max_bytes) .. "-byte limit"
        end
        return nil, M.error_text(status, err)
    end

    local headers = M.headers_blob_to_table(blob)
    if req_opts.sink then
        if body_data and #body_data > 0 then
            local ok, sink_err = req_opts.sink(body_data)
            if not ok then return nil, sink_err end
        end
        local ok, sink_err = req_opts.sink(nil)
        if not ok then return nil, sink_err end
    end
    return 1, status, headers, nil
end

-- 后端选择入口：transport 层调用。k4tls 不可用/被禁用时返回 nil（回退）。
function M.select(backend)
    local chosen = backend or M.backend
    local env = os.getenv and os.getenv("WEREAD_TLS_BACKEND") or nil
    if env and env ~= "" then chosen = env end
    if chosen ~= "auto" and chosen ~= "k4tls" then
        return nil, "backend forced to luasec"
    end
    if not M.is_available() then
        return nil, "k4tls not loadable"
    end
    return M, nil
end

return M
