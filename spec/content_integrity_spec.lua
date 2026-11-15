-- D-03/D-05 (2026-11-15 user audit) regression specs.
-- D-03: base64_decode correctness incl. large inputs (byte-identical to the
-- legacy decoder, now byte-index table + FFI buffer/chunked fallback).
-- D-05: spool_body_complete rejects corrupted bodies (length matches, md5 not).

local __SPEC_STUB_NAMES = {"weread.lib.logger", "weread.lib.settings", "pluginshare",
    "ui/uimanager", "device", "libs/libkoreader-lfs", "weread.lib.crypto",
    "weread.lib.plugin_util", "weread.lib.book_store", "weread.lib.protocol",
    "weread.lib.footnotes", "weread.lib.foreground_barrier", "ui/time",
    "ffi/util", "weread.lib.content", "weread.lib.downloader"}
local __PREEXISTING = {}
for _, name in ipairs(__SPEC_STUB_NAMES) do
    __PREEXISTING[name] = { loaded = package.loaded[name], preload = package.preload[name] }
end
teardown(function()
    for name, saved in pairs(__PREEXISTING) do
        package.loaded[name] = saved.loaded
        package.preload[name] = saved.preload
    end
end)

local function preload_stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = factory()
end

preload_stub("weread.lib.logger", function()
    return { info = function() end, warn = function() end, err = function() end,
        scoped = function() return { info=function() end, warn=function() end, err=function() end } end }
end)
preload_stub("weread.lib.settings", function() return {} end)
preload_stub("pluginshare", function() return {} end)
preload_stub("ui/uimanager", function()
    return { scheduleIn = function(_s, _d, fn) fn() end, unschedule = function() end,
        show = function() end, preventStandby = function() end, allowStandby = function() end,
        forceRePaint = function() end, close = function() end }
end)
preload_stub("device", function()
    return { isKindle = function() return false end, isCervantes = function() return false end,
        isKobo = function() return false end }
end)
preload_stub("libs/libkoreader-lfs", function()
    return { dir = function() return nil, nil end, attributes = function() return nil end }
end)
preload_stub("ui/time", function()
    local t = 1000000
    return { now = function() t = t + 1; return t end }
end)
preload_stub("ffi/util", function() return { template = function(text) return text end } end)
preload_stub("weread.lib.crypto", function()
    -- md5_hex stub: deterministic pseudo-digest over content length+head so the
    -- integrity spec can round-trip without real md5.
    return { md5_hex = function(data)
        local acc = 0
        for i = 1, #data do acc = (acc + data:byte(i) * i) % 0xFFFFFFFF end
        return string.format("%08X%08X", acc, #data)
    end }
end)
preload_stub("weread.lib.plugin_util", function()
    return { mkdirs = function() end }
end)
preload_stub("weread.lib.book_store", function() return {} end)
preload_stub("weread.lib.protocol", function()
    return { urlencode = function(v) return tostring(v) end,
        reader_url = function() return "https://weread.qq.com/web/reader/x" end,
        is_mp_book = function() return false end,
        normalize_cover_url = function(u) return u end }
end)
preload_stub("weread.lib.footnotes", function()
    return { scan_chapter = function() return { definitions={}, refs={}, anchors={},
        definition_backlinks={}, forward_ref_ids={} } end,
        build_book_index = function() return {} end,
        transform_chapter = function(h) return h end, validate = function() return true end }
end)
preload_stub("weread.lib.foreground_barrier", function() return {} end)
preload_stub("weread.ui.download_dialog", function() return {} end)

-- Other spec files (e.g. downloader_resume_spec) stub "bit" as an empty
-- table in the shared busted Lua state. Force-load the real bit library
-- before content.lua requires it, clearing any earlier stub.
local bit = require("bit")
Content = require("weread.lib.content")

describe("base64_decode (D-03 rewrite)", function()
    -- (acc >> 16) replaced with math.floor(acc/65536) for Lua 5.1
    local bit = require("bit")
    local function b64_encode(data)
        local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        local out = {}
        local len = #data
        for i = 1, len - len % 3, 3 do
            local a, b, c = data:byte(i, i + 2)
            out[#out + 1] = chars:sub(bit.rshift(a, 2) + 1, bit.rshift(a, 2) + 1)
            out[#out + 1] = chars:sub(bit.band(a, 3) * 16 + bit.rshift(b, 4) + 1, bit.band(a, 3) * 16 + bit.rshift(b, 4) + 1)
            out[#out + 1] = chars:sub(bit.band(b, 15) * 4 + bit.rshift(c, 6) + 1, bit.band(b, 15) * 4 + bit.rshift(c, 6) + 1)
            out[#out + 1] = chars:sub(bit.band(c, 63) + 1, bit.band(c, 63) + 1)
        end
        local rem = len % 3
        if rem == 1 then
            local a = data:byte(len)
            out[#out + 1] = chars:sub(bit.rshift(a, 2) + 1, bit.rshift(a, 2) + 1)
            out[#out + 1] = chars:sub(bit.band(a, 3) * 16 + 1, bit.band(a, 3) * 16 + 1)
            out[#out + 1] = "=="
        elseif rem == 2 then
            local a, b = data:byte(len - 1, len)
            out[#out + 1] = chars:sub(bit.rshift(a, 2) + 1, bit.rshift(a, 2) + 1)
            out[#out + 1] = chars:sub(bit.band(a, 3) * 16 + bit.rshift(b, 4) + 1, bit.band(a, 3) * 16 + bit.rshift(b, 4) + 1)
            out[#out + 1] = chars:sub(bit.band(b, 15) * 4 + 1, bit.band(b, 15) * 4 + 1)
            out[#out + 1] = "="
        end
        return table.concat(out)
    end

    it("round-trips RFC 4648 vectors", function()
        assert.equals("", Content.base64_decode(""))
        assert.equals("f", Content.base64_decode(b64_encode("f")))
        assert.equals("fo", Content.base64_decode(b64_encode("fo")))
        assert.equals("foo", Content.base64_decode(b64_encode("foo")))
        assert.equals("foob", Content.base64_decode(b64_encode("foob")))
        assert.equals("fooba", Content.base64_decode(b64_encode("fooba")))
        assert.equals("foobar", Content.base64_decode(b64_encode("foobar")))
    end)

    it("handles URL-safe alphabet and missing padding", function()
        local encoded = b64_encode("foobar"):gsub("+", "-"):gsub("/", "_"):gsub("=", "")
        assert.equals("foobar", Content.base64_decode(encoded))
    end)

    it("round-trips a 2MB body byte-identically (D-03 large-input regression)", function()
        -- deterministic pseudo-random body spanning all byte values
        local parts = {}
        local acc = 12345
        for _ = 1, 2048 do
            local chunk = {}
            for _ = 1, 1024 do
                acc = (acc * 1103515245 + 12345) % 0x100000000
                chunk[#chunk + 1] = string.char(math.floor(acc / 65536) % 256)
            end
            parts[#parts + 1] = table.concat(chunk)
        end
        local body = table.concat(parts)
        assert.equals(2 * 1024 * 1024, #body)
        assert.equals(body, Content.base64_decode(b64_encode(body)))
    end)
end)

local Crypto = require("weread.lib.crypto")
describe("spool_body_complete integrity (D-05)", function()
    local memfs = {}
    local book = { book_id = "B1" }

    setup(function()
        Content.write_file = function(path, data) memfs[path] = data end
        Content.read_file = function(path) return memfs[path] end
        Content.spool_dir = function() return "/mem/.dl" end
    end)

    teardown(function()
        memfs = {}
    end)

    local function meta_path(uid)
        return "/mem/.dl/chapters/" .. tostring(uid) .. ".meta"
    end

    it("accepts a spool whose length and md5 both match", function()
        local body = "chapter-body-123"
        memfs[meta_path("u1")] = "length=" .. #body .. "\nmd5=" .. Crypto.md5_hex(body):upper()
        assert.is_true(Content.spool_body_complete({}, book, "u1", body))
    end)

    it("rejects a body whose length matches but content was corrupted (D-05)", function()
        memfs[meta_path("u2")] = "length=16\nmd5=" .. Crypto.md5_hex("chapter-body-123"):upper()
        assert.is_false(Content.spool_body_complete({}, book, "u2", "chapter-body-XX4"))
    end)

    it("stays lenient for legacy length-only spools", function()
        memfs[meta_path("u3")] = "length=16"
        assert.is_true(Content.spool_body_complete({}, book, "u3", "0123456789abcdef"))
    end)

    it("rejects when length mismatches (existing behavior)", function()
        memfs[meta_path("u4")] = "length=99"
        assert.is_false(Content.spool_body_complete({}, book, "u4", "short"))
    end)
end)
