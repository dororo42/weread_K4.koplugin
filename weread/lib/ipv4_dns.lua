-- P0-A (2026-09-18, crash-report E3): IPv4-first DNS resolution for the K4.
--
-- Background: the Kindle 4 runs Linux 2.6.31 with NO IPv6 stack, but
-- weread.qq.com publishes AAAA records. When getaddrinfo returns an IPv6
-- literal first, LuaSocket's AF_INET socket fails with
-- "Address family not supported by protocol" (EAFNOSUPPORT) — observed
-- on-device 2026-09-17 20:54:56 (81 ms fast-fail, self-healed next tick).
--
-- This module owns two independent defenses so both stay unit-testable
-- without LuaSocket:
--   1. M.apply(socket) — replaces socket.dns.toip with an IPv4-filtering
--      wrapper (A-records only; falls back to the stock resolver whenever
--      anything is unexpected, so the patch can never introduce a NEW
--      failure mode).
--   2. M.is_resolution_error(text) — classifies the transport errors that
--      are worth one immediate retry inside Client:request() (family
--      mismatch + fast DNS resolution failures; deliberately NOT
--      timeouts, which would double the worst-case UI freeze).
local M = {}

-- Substrings (lowercase) that mark a resolution-class transport error.
-- "Address family not supported by protocol" is the E3 signature (an IPv6
-- literal handed to an AF_INET socket). The DNS-failure strings are the
-- stock LuaSocket/getaddrinfo texts; they fail fast, so a single retry
-- re-runs resolution without meaningfully extending the UI freeze.
local RESOLUTION_ERROR_PATTERNS = {
    "address family not supported",
    "eafnosupport",
    "host or service not provided",
    "no address associated with name",
    "name or service not known",
}

function M.is_resolution_error(err)
    local text = tostring(err or ""):lower()
    for _i, pattern in ipairs(RESOLUTION_ERROR_PATTERNS) do
        if text:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

-- Patch socket.dns.toip so weread hosts resolve to A-records only.
-- Returns true when the patch was applied (or was already in place),
-- false when the host's LuaSocket lacks the expected surface — callers
-- must treat false as "stock behavior unchanged", never as an error.
function M.apply(socket)
    if type(socket) ~= "table" or type(socket.dns) ~= "table" then
        return false
    end
    local dns = socket.dns
    if type(dns.toip) ~= "function" or type(dns.getaddrinfo) ~= "function" then
        return false
    end
    if dns._weread_ipv4_patch then
        return true
    end
    local original_toip = dns.toip
    dns.toip = function(host, all)
        local ok_info, info = pcall(dns.getaddrinfo, host)
        if ok_info and type(info) == "table" and #info > 0 then
            local ipv4 = {}
            for _i, entry in ipairs(info) do
                if type(entry) == "table" and entry.family == "inet"
                        and entry.addr ~= nil then
                    ipv4[#ipv4 + 1] = entry.addr
                end
            end
            if ipv4[1] ~= nil then
                -- toip(host, all) returns the full table in stock LuaSocket;
                -- mirror that shape so no caller can tell the difference.
                if all then return ipv4 end
                return ipv4[1]
            end
            -- AAAA-only environment: fall through to the stock resolver so
            -- behavior matches unpatched LuaSocket (Client:request() owns
            -- the resulting failure with its one-shot retry).
        end
        return original_toip(host, all)
    end
    dns._weread_ipv4_patch = true
    return true
end

return M
