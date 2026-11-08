-- 默认 LuaSec；只有显式 auto/k4tls 才探测 Rust 后端。
local M = {
    _NAME = "weread.lib.transport",
    backend = "luasec",
}

local k4tls_ok, k4tls = pcall(require, "weread.lib.k4tls")
local http_ok, http = pcall(require, "socket.http")

function M.resolve()
    local chosen = M.backend
    local env = os.getenv and os.getenv("WEREAD_TLS_BACKEND") or nil
    if env and env ~= "" then chosen = env end
    if chosen ~= "auto" and chosen ~= "k4tls" then
        return nil, "luasec"
    end
    if k4tls_ok and k4tls and k4tls.is_available() then
        return k4tls, "k4tls"
    end
    return nil, "luasec-fallback"
end

function M.request(req_opts)
    local backend = M.resolve()
    if backend then
        return backend.request(req_opts)
    end
    if not http_ok or not http then
        return nil, "transport: no backend available"
    end
    return http.request(req_opts)
end

return M
