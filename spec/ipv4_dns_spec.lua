-- P0-A (2026-09-18, crash-report E3) unit tests for weread/lib/ipv4_dns.lua.
-- The module is dependency-free on purpose: socket.dns is injected, so the
-- IPv4 filter, the AAAA-only fallback and the resolution-error classifier
-- can be exercised without LuaSocket.

local ipv4_dns = require("weread.lib.ipv4_dns")

local function fake_socket(getaddrinfo_result, getaddrinfo_err)
    local calls = { toip_fallback = 0 }
    local socket = {
        dns = {
            getaddrinfo = function(_host)
                if getaddrinfo_err then
                    error(getaddrinfo_err)
                end
                return getaddrinfo_result
            end,
            toip = function(_host, _all)
                calls.toip_fallback = calls.toip_fallback + 1
                return "original-answer"
            end,
        },
    }
    return socket, calls
end

describe("ipv4_dns.is_resolution_error (P0-A)", function()
    it("matches the E3 EAFNOSUPPORT signature", function()
        assert.is_true(ipv4_dns.is_resolution_error(
            "Address family not supported by protocol"))
        assert.is_true(ipv4_dns.is_resolution_error("eafnosupport"))
    end)

    it("matches fast DNS resolution failures", function()
        assert.is_true(ipv4_dns.is_resolution_error(
            "host or service not provided"))
        assert.is_true(ipv4_dns.is_resolution_error(
            "no address associated with name"))
        assert.is_true(ipv4_dns.is_resolution_error(
            "name or service not known"))
    end)

    it("does NOT match timeouts or resets (never retried here)", function()
        assert.is_false(ipv4_dns.is_resolution_error("timeout"))
        assert.is_false(ipv4_dns.is_resolution_error("closed"))
        assert.is_false(ipv4_dns.is_resolution_error("connection refused"))
        assert.is_false(ipv4_dns.is_resolution_error(nil))
    end)
end)

describe("ipv4_dns.apply (P0-A)", function()
    it("resolves to the first A record when one exists", function()
        local socket = fake_socket({
            { family = "inet6", addr = "2402:4e00::1" },
            { family = "inet", addr = "203.205.147.1" },
            { family = "inet", addr = "203.205.147.2" },
        })
        assert.is_true(ipv4_dns.apply(socket))
        assert.equals("203.205.147.1", socket.dns.toip("weread.qq.com"))
    end)

    it("mirrors toip(host, all) and returns the IPv4 table", function()
        local socket = fake_socket({
            { family = "inet", addr = "203.205.147.1" },
        })
        ipv4_dns.apply(socket)
        local all = socket.dns.toip("weread.qq.com", true)
        assert.equals("203.205.147.1", all[1])
    end)

    it("falls back to the stock resolver in an AAAA-only environment", function()
        local socket, calls = fake_socket({
            { family = "inet6", addr = "2402:4e00::1" },
        })
        ipv4_dns.apply(socket)
        assert.equals("original-answer", socket.dns.toip("weread.qq.com"))
        assert.equals(1, calls.toip_fallback)
    end)

    it("falls back when getaddrinfo errors", function()
        local socket, calls = fake_socket(nil, "resolver exploded")
        ipv4_dns.apply(socket)
        assert.equals("original-answer", socket.dns.toip("weread.qq.com"))
        assert.equals(1, calls.toip_fallback)
    end)

    it("returns false and touches nothing without the expected surface", function()
        assert.is_false(ipv4_dns.apply(nil))
        assert.is_false(ipv4_dns.apply({}))
        assert.is_false(ipv4_dns.apply({ dns = { toip = function() end } }))
        local socket = fake_socket(nil)
        socket.dns.getaddrinfo = nil
        assert.is_false(ipv4_dns.apply(socket))
    end)

    it("is idempotent (a second apply does not double-wrap)", function()
        local socket = fake_socket({
            { family = "inet", addr = "1.2.3.4" },
        })
        assert.is_true(ipv4_dns.apply(socket))
        local wrapped = socket.dns.toip
        assert.is_true(ipv4_dns.apply(socket))
        assert.equals(wrapped, socket.dns.toip)
        assert.is_true(socket.dns._weread_ipv4_patch)
    end)
end)
