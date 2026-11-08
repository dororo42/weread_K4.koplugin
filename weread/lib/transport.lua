-- transport.lua — client.lua 的传输后端选择器（K4WereadRust P1-A 集成件）。
-- client.lua 唯一改动点：`http.request` → `transport.request`（语义形状一致）。
-- 选择规则（R2 回退开关，R4 bench 前默认不启用 k4tls）：
--   1) 环境变量 WEREAD_TLS_BACKEND / 模块设置 backend 优先；
--   2) "auto" 且 k4tls 可加载 → k4tls；
--   3) 其余（"luasec"、加载失败、ffi 不可用）→ socket.http 原路径。
-- 任何 k4tls 侧意外错误不允许静默吞掉：由 client.lua 既有 pcall/分类逻辑处理。

local M = {
    _NAME = "weread.lib.transport",
    -- 设备/测试可覆盖："auto" | "luasec"
    backend = "auto",
}

local k4tls_ok, k4tls = pcall(require, "weread.lib.k4tls")
local http_ok, http = pcall(require, "socket.http")

function M.resolve()
    local chosen = M.backend
    local env = os.getenv and os.getenv("WEREAD_TLS_BACKEND") or nil
    if env and env ~= "" then chosen = env end
    if chosen ~= "k4tls" and chosen ~= "luasec" then chosen = "auto" end
    if chosen == "luasec" then
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
        return 1, nil, "transport: no backend available"
    end
    return http.request(req_opts)
end

return M
