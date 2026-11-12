-- 默认 LuaSec；只有显式 auto/k4tls 才探测 Rust 后端。
local M = {
    _NAME = "weread.lib.transport",
    backend = "luasec",
    -- 2026-11-12：菜单显式选择标志——true 时 WEREAD_TLS_BACKEND 部署默认
    -- 失效（否则菜单勾选永远赢不了 koreader.sh 的 export）。init 时由
    -- settings.tls_backend 恢复，菜单回调置位。
    backend_explicit = false,
    -- 最近一次 resolve 的诊断原因；强制 k4tls 却加载失败时可被日志检索，
    -- 不改变 request 的 (1, code, headers) / (nil, err) 契约。
    last_reason = nil,
}

local k4tls_ok, k4tls = pcall(require, "weread.lib.k4tls")
local http_ok, http = pcall(require, "socket.http")

function M.resolve()
    local chosen = M.backend
    local env = os.getenv and os.getenv("WEREAD_TLS_BACKEND") or nil
    -- 2026-11-12：菜单显式选择（backend_explicit）优先于部署侧 env 默认，
    -- 否则菜单勾选无法覆盖 koreader.sh 的 export；env 仅在用户未显式
    -- 选择时作为部署默认生效（进行中的 A/B 观察不受影响）。
    if env and env ~= "" and not M.backend_explicit then
        chosen = env
    end
    if chosen ~= "auto" and chosen ~= "k4tls" then
        M.last_reason = "luasec"
        return nil, "luasec"
    end
    if k4tls_ok and k4tls and k4tls.is_available() then
        M.last_reason = "k4tls"
        return k4tls, "k4tls"
    end
    -- 显式强制 k4tls 而库不可加载：保留回退行为，但给出可检索的原因，
    -- 避免部署/翻闸验收把「库没装上」误当成正常 LuaSec 成功。
    M.last_reason = chosen == "k4tls" and "k4tls-unavailable-fallback" or "luasec-fallback"
    return nil, M.last_reason
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
