-- B-4 (2026-10-20 audit): pre-publish EPUB package verification ("开包验数").
-- Content.verify_epub_package parses the zip EOCD of the assembled tmp
-- archive in pure Lua and refuses to bless a truncated archive. The heavy
-- deps of weread.lib.content are stubbed (same set as
-- content_css_sanitize_spec.lua); the EOCD parser is exercised with
-- hand-crafted zip structures written to temp files.
package.preload["bit"] = function() return {} end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.book_store"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end

local Content = require("weread.lib.content")

local function u16le(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
end
local function u32le(v)
    return u16le(v % 65536) .. u16le(math.floor(v / 65536))
end
-- Minimal EOCD: sig + disk# + cd-disk + entries-on-disk + total + cd_size
-- + cd_offset + comment_len [+ comment].
local function eocd(total, entries_on_disk, comment)
    comment = comment or ""
    return "PK\005\006" .. u16le(0) .. u16le(0)
        .. u16le(entries_on_disk or total) .. u16le(total)
        .. u32le(42) .. u32le(100) .. u16le(#comment) .. comment
end
local function write_tmp(blob)
    local path = os.tmpname()
    local f = assert(io.open(path, "wb"))
    f:write(blob)
    f:close()
    return path
end
local function rm(path)
    if path then os.remove(path) end
end

describe("Content.verify_epub_package (B-4 pre-publish gate)", function()
    it("accepts an archive whose EOCD records enough entries", function()
        local path = write_tmp("PK\003\004-local-bytes" .. eocd(7))
        local ok, total = Content.verify_epub_package(path, 4)
        assert.is_true(ok)
        assert.equals(7, total)
        rm(path)
    end)

    it("accepts a nil minimum by defaulting to 4", function()
        local path = write_tmp(eocd(4))
        local ok, total = Content.verify_epub_package(path)
        assert.is_true(ok)
        assert.equals(4, total)
        rm(path)
    end)

    it("rejects an entry count below the expected minimum", function()
        -- Streamed assembly counted 9 added files; EOCD says 2 → truncated.
        local path = write_tmp(eocd(2))
        local ok, err = Content.verify_epub_package(path, 9)
        assert.is_nil(ok)
        assert.is_not_nil(err:find("2 < expected minimum 9", 1, true))
        rm(path)
    end)

    it("finds the EOCD even behind a zip comment", function()
        local path = write_tmp(eocd(12, 12, "trailing archive comment"))
        local ok, total = Content.verify_epub_package(path, 4)
        assert.is_true(ok)
        assert.equals(12, total)
        rm(path)
    end)

    it("uses the LAST EOCD when decoy bytes are present", function()
        -- A comment containing fake EOCD-looking bytes earlier in the file
        -- must not win; the scan starts from the end.
        local decoy = "junkPK\005\006" .. string.rep("\000", 18)
        local path = write_tmp(decoy .. eocd(5))
        local ok, total = Content.verify_epub_package(path, 4)
        assert.is_true(ok)
        assert.equals(5, total)
        rm(path)
    end)

    it("rejects files too small to hold an EOCD", function()
        local path = write_tmp("PK\005\006trunc")
        local ok, err = Content.verify_epub_package(path, 4)
        assert.is_nil(ok)
        assert.is_not_nil(err:find("too small", 1, true))
        rm(path)
    end)

    it("rejects data without an EOCD record", function()
        local path = write_tmp(string.rep("A", 4096))
        local ok, err = Content.verify_epub_package(path, 4)
        assert.is_nil(ok)
        assert.is_not_nil(err:find("no zip EOCD", 1, true))
        rm(path)
    end)

    it("rejects a missing file", function()
        local ok, err = Content.verify_epub_package("/nonexistent/epub_verify.tmp", 4)
        assert.is_nil(ok)
        assert.is_not_nil(err:find("cannot open", 1, true))
    end)
end)
