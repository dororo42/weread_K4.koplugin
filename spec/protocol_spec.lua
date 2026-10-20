-- Unit tests for weread/lib/protocol.lua (N-2, 2026-10-20 audit): the module
-- previously had zero direct coverage — the module-map gate now requires a
-- spec for it. Covers the pure helpers (urlencode / sorted_query /
-- is_success_response / sign / e / utf8_substr / URL builders).
--
-- Module-load dependencies are stubbed: LuaJIT's `bit` (not present under
-- the Lua 5.1 busted runtime) and the ffi-backed Crypto (device-only). The
-- bit emulation below reproduces LuaJIT semantics for the non-negative
-- 32-bit domain sign() operates in and is self-tested first.
--
-- NOTE: busted runs all specs in ONE Lua state AND loads every spec file's
-- top-level code BEFORE running any of them. Other specs (path_guard,
-- prefetch_guard, ...) leave `package.preload["weread.lib.protocol"]`
-- factories behind during that load phase, which would shadow the real
-- module. So the stubs are installed lazily via P() (run phase) and torn
-- down by *clearing* the entries (not restoring load-phase snapshots, which
-- may themselves be other specs' factories).
local bit = {}
local function bxor(a, b)
    local result, weight = 0, 1
    a, b = math.floor(a), math.floor(b)
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if x ~= y then
            result = result + weight
        end
        a, b = (a - x) / 2, (b - y) / 2
        weight = weight * 2
    end
    return result
end
local function band(a, b)
    local result, weight = 0, 1
    a, b = math.floor(a), math.floor(b)
    for _ = 1, 32 do
        if a % 2 == 1 and b % 2 == 1 then
            result = result + weight
        end
        a, b = (a - a % 2) / 2, (b - b % 2) / 2
        weight = weight * 2
    end
    return result
end
bit.bxor = bxor
bit.band = band
bit.lshift = function(x, n) return (math.floor(x) * 2 ^ n) % 4294967296 end

-- Deterministic md5 stand-in: e()'s structure becomes fully predictable.
local function crypto_stub_factory()
    return {
        md5_hex = function(_s) return "0123456789abcdef0123456789abcdef" end,
        sha1_hex = function(_s) return "0123456789abcdef0123456789abcdef01234567" end,
        sha256_hex = function(_s) return string.rep("0", 64) end,
    }
end

local function install_stubs()
    package.preload["bit"] = function() return bit end
    package.loaded["bit"] = bit
    package.preload["weread.lib.crypto"] = crypto_stub_factory
    package.loaded["weread.lib.crypto"] = crypto_stub_factory()
    package.preload["weread.lib.protocol"] = nil
    package.loaded["weread.lib.protocol"] = nil
end

local function uninstall_stubs()
    for _, name in ipairs({ "bit", "weread.lib.crypto", "weread.lib.protocol" }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

local WeRead
local function P()
    install_stubs()
    if not WeRead then
        WeRead = require("weread.lib.protocol")
    end
    return WeRead
end

describe("bit emulation self-check (spec harness)", function()
    it("matches known 32-bit results", function()
        assert.equals(6, bit.bxor(5, 3))
        assert.equals(1, bit.band(3, 1))
        assert.equals(196, bit.lshift(98, 1))
        -- lshift wraps at 32 bits like LuaJIT: 255<<29 = 0xE_0000_0000 → 0xE0000000
        assert.equals(3758096384, bit.lshift(255, 29))
        -- a full 32-bit shift wraps to zero
        assert.equals(0, bit.lshift(1, 32))
        assert.equals(0, bit.band(0x15051505, 0))
    end)
end)

describe("Protocol urlencode / sorted_query", function()
    teardown(uninstall_stubs)

    it("percent-encodes everything outside the unreserved set", function()
        assert.equals("abc", P().urlencode("abc"))
        assert.equals("a%20b", P().urlencode("a b"))
        assert.equals("a%2Fb", P().urlencode("a/b"))
        assert.equals("%E4%B8%AD", P().urlencode("中"))
        assert.equals("a-b_c.d~e", P().urlencode("a-b_c.d~e"))
    end)

    it("renders booleans and nil like the web reader's js_string", function()
        assert.equals("true", P().urlencode(true))
        assert.equals("false", P().urlencode(false))
        assert.equals("null", P().urlencode(nil))
    end)

    it("sorts params by key and excludes the s signature", function()
        local query = P().sorted_query({ b = "2", a = "1", s = "sig" })
        assert.equals("a=1&b=2", query)
    end)

    it("encodes values inside the sorted query", function()
        local query = P().sorted_query({ k = "a b&c" })
        assert.equals("k=a%20b%26c", query)
    end)
end)

describe("Protocol is_success_response", function()
    teardown(uninstall_stubs)

    it("accepts succ true and numeric 1 in any field", function()
        assert.is_true(P().is_success_response({ succ = true }))
        assert.is_true(P().is_success_response({ succ = 1 }))
        assert.is_true(P().is_success_response({ succ = "1" }))
        assert.is_true(P().is_success_response({ ok = 1 }, "ok"))
    end)

    it("rejects missing, false, zero and non-table results", function()
        assert.is_false(P().is_success_response({}))
        assert.is_false(P().is_success_response({ succ = false }))
        assert.is_false(P().is_success_response({ succ = 0 }))
        assert.is_false(P().is_success_response("nope"))
        assert.is_false(P().is_success_response(nil))
    end)
end)

describe("Protocol sign", function()
    teardown(uninstall_stubs)

    -- Hand-computed vector for query "ab":
    --   a = band(bxor(0x15051505, lshift(98, 1)), 0x7fffffff) = 0x150515C1
    --   b = band(bxor(0x15051505, lshift(97, 1)), 0x7fffffff) = 0x150515C7
    --   sign = %x(0x150515C1 + 0x150515C7) = "2a0a2b88"
    it("reproduces the hand-computed vector for a two-byte query", function()
        assert.equals("2a0a2b88", P().sign("ab"))
    end)

    it("is deterministic and input-sensitive", function()
        assert.equals(P().sign("chapter=1"), P().sign("chapter=1"))
        assert.is_not_nil(P().sign("chapter=1"):match("^%x+$"))
        assert.are_not.equals(P().sign("chapter=1"), P().sign("chapter=2"))
    end)
end)

describe("Protocol e (obfuscated id)", function()
    teardown(uninstall_stubs)

    -- With the deterministic md5 stub ("0123456789abcdef…"):
    --   e("abc"): h:sub(1,3)="012", type_flag="4", byte_hex("abc")="616263"
    --   → "012".."4".."2".."ef" .. ("06".."616263")            = "01242ef06616263"
    --   → padded to 20 with h:sub(1,5)="01234"
    --   → .. md5(result):sub(1,3)="012"
    it("reproduces the traced structure for a non-digit input", function()
        assert.equals("01242ef0661626301234012", P().e("abc"))
    end)

    it("uses the digit branch for numeric strings", function()
        local out = P().e("123456789")
        -- digit strings take the "3" type flag and 9-digit chunks
        assert.is_not_nil(out:find("32", 1, true))
        assert.equals("012", out:sub(-3))
    end)
end)

describe("Protocol utf8_substr and URL builders", function()
    teardown(uninstall_stubs)

    it("truncates by characters, not bytes", function()
        assert.equals("中文", P().utf8_substr("中文字符", 2))
        assert.equals("abc", P().utf8_substr("abcdef", 3))
        assert.equals("", P().utf8_substr("abc", 0))
    end)

    it("builds reader URLs from the obfuscated id", function()
        -- e("abc") = "01242ef0661626301234012" (verified in the e() spec above)
        assert.equals("https://weread.qq.com/web/reader/01242ef0661626301234012",
            P().reader_url("abc"))
        -- chapter is appended as "k" .. e(chapter_uid), not a query param
        assert.equals("https://weread.qq.com/web/reader/01242ef0661626301234012"
            .. "k" .. P().e(42), P().reader_url("abc", 42))
    end)

    it("detects MP articles by the MP_WXS_ prefix", function()
        assert.is_true(P().is_mp_book("MP_WXS_12345"))
        assert.is_false(P().is_mp_book("MP_123"))
        assert.is_false(P().is_mp_book("123"))
        assert.is_false(P().is_mp_book(nil))
    end)

    it("upgrades cover URLs to the t9 token", function()
        assert.equals("https://wered.127.net/t9_x.jpg",
            (P().normalize_cover_url("https://wered.127.net/t7_x.jpg")))
        assert.equals("https://wered.127.net/t9_x.jpg",
            (P().normalize_cover_url("https://wered.127.net/t9_x.jpg")))
        assert.equals("plain.jpg", (P().normalize_cover_url("plain.jpg")))
        assert.is_nil(P().normalize_cover_url(nil))
    end)
end)
