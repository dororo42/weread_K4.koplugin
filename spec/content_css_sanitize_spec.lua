-- Busted port of the upstream PR #137 regression suite
-- (spec/content_css_sanitize_spec.lua in finlater/weread.koplugin v1.4.0,
-- +139 lines). Content.sanitize_book_css is a pure function with no API
-- divergence in the K4 fork, so only the harness style changes.
--
-- Heavy dependencies of weread.lib.content are stubbed out; the module only
-- needs them at require time for the paths these tests do not exercise.
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

describe("Content.sanitize_book_css (upstream PR #137)", function()
    -- The hostile rule observed in real WeRead e_2 shards: crengine honors the
    -- root-element zero sizing and p{font-size:1rem} then collapses the whole
    -- book.
    local hostile = "html,\nbody {\n  margin: 0;\n  padding: 0;\n  font-size: 0;\n  }"

    it("strips the root-element font-size:0 rule and keeps siblings", function()
        local cleaned, count = Content.sanitize_book_css(hostile)
        assert.equals(1, count)
        assert.is_nil(cleaned:find("font%-size"))
        assert.is_not_nil(cleaned:find("{", 1, true))
        assert.is_not_nil(cleaned:find("}", 1, true))
        assert.is_not_nil(cleaned:find("margin: 0;", 1, true))
        assert.is_not_nil(cleaned:find("padding: 0;", 1, true))
    end)

    it("never touches intentional font-size:0 outside root selectors", function()
        local cleaned, count = Content.sanitize_book_css(
            ".a{font-size: 0 !important;color:red}")
        assert.equals(0, count)
        assert.equals(".a{font-size: 0 !important;color:red}", cleaned)

        cleaned, count = Content.sanitize_book_css(".slide-nav { font-size: 0 }")
        assert.equals(0, count)
        assert.equals(".slide-nav { font-size: 0 }", cleaned)

        -- A descendant-of-body selector also styles other content.
        cleaned, count = Content.sanitize_book_css("body p{font-size:0}")
        assert.equals(0, count)
        assert.equals("body p{font-size:0}", cleaned)

        -- A selector list mixing body with other targets never qualifies.
        cleaned, count = Content.sanitize_book_css("body,.wrapper{font-size:0}")
        assert.equals(0, count)
        assert.equals("body,.wrapper{font-size:0}", cleaned)
    end)

    it("matches root selectors case- and whitespace-insensitively", function()
        local cleaned, count = Content.sanitize_book_css("HTML ,\nBODY { font-size: 0 }")
        assert.equals(1, count)
        assert.is_nil(cleaned:find("font%-size"))
    end)

    it("leaves :root and @media-wrapped root rules alone (deliberate limits)", function()
        local cleaned, count = Content.sanitize_book_css(":root{font-size:0}")
        assert.equals(0, count)
        assert.equals(":root{font-size:0}", cleaned)

        local media_css = "@media print { html, body { font-size: 0 } }"
        cleaned, count = Content.sanitize_book_css(media_css)
        assert.equals(0, count)
        assert.equals(media_css, cleaned)
    end)

    it("still matches the rule after a preceding at-rule", function()
        local cleaned, count = Content.sanitize_book_css(
            '@charset "utf-8";html,body{font-size:0}')
        assert.equals(1, count)
        assert.is_nil(cleaned:find("font%-size"))
    end)

    it("removes zero sizes with px/% units but keeps fractional and non-zero sizes", function()
        local cleaned, count = Content.sanitize_book_css(
            "html{font-size: 0px}body{font-size: 0%;}")
        assert.equals(2, count)
        assert.is_nil(cleaned:find("font%-size"))

        cleaned, count = Content.sanitize_book_css(".fs05 { font-size: 0.5rem; }")
        assert.equals(0, count)
        assert.equals(".fs05 { font-size: 0.5rem; }", cleaned)

        cleaned, count = Content.sanitize_book_css("html, body { font-size: 0.5rem; }")
        assert.equals(0, count)
        assert.equals("html, body { font-size: 0.5rem; }", cleaned)

        cleaned, count = Content.sanitize_book_css("p { font-size: 1rem; }")
        assert.equals(0, count)
        assert.equals("p { font-size: 1rem; }", cleaned)
    end)

    it("leaves a selectorless block untouched", function()
        local cleaned, count = Content.sanitize_book_css(
            "{ color: #000; font-size: 0\n}")
        assert.equals(0, count)
        assert.is_not_nil(cleaned:find("font-size: 0", 1, true))
    end)

    it("passes nil and empty input through with count 0", function()
        local passthrough, count = Content.sanitize_book_css(nil)
        assert.equals(nil, passthrough)
        assert.equals(0, count)
        passthrough, count = Content.sanitize_book_css("")
        assert.equals("", passthrough)
        assert.equals(0, count)
    end)

    it("is idempotent on a combined shard", function()
        -- Integration-style: sanitizing an already-sanitized shard changes
        -- nothing. Only the root rule qualifies; other blocks keep theirs.
        local combined = table.concat({
            hostile,
            ".a{font-size: 0 !important;color:red}",
            "p{font-size: 0px}h1{font-size: 0%;}",
            "{ color: #000; font-size: 0\n}",
        }, "\n")
        local once, first_count = Content.sanitize_book_css(combined)
        local twice, second_count = Content.sanitize_book_css(once)
        assert.equals(1, first_count)
        assert.equals(0, second_count)
        assert.equals(once, twice)
    end)

    it("iterates to a fixpoint for adjacent zero declarations", function()
        -- Each pass consumes one boundary character, so adjacent zeros need
        -- repeated passes instead of keeping the second one.
        local cleaned, count = Content.sanitize_book_css(
            "html,body{font-size:0;font-size:0}")
        assert.equals(2, count)
        assert.is_nil(cleaned:find("font%-size"))
        assert.is_not_nil(cleaned:find("^html,body%{.*%}$"))

        cleaned, count = Content.sanitize_book_css(
            "html,body{font-size:0 ;font-size:0 ;color:red}")
        assert.equals(2, count)
        assert.is_not_nil(cleaned:find("color:red", 1, true))

        -- Zero with any letter unit (0vh) is a zero length.
        cleaned, count = Content.sanitize_book_css("html,body{font-size:0vh}")
        assert.equals(1, count)
        assert.is_nil(cleaned:find("font%-size"))
    end)

    it("keeps the block structurally valid when rewriting a CSS comment", function()
        local commented = "body{ /* font-size: 0 ; old */ color:blue }"
        local cleaned, count = Content.sanitize_book_css(commented)
        local open_braces = select(2, cleaned:gsub("%{", ""))
        local close_braces = select(2, cleaned:gsub("}", ""))
        assert.equals(1, count)
        assert.is_not_nil(cleaned:find("color:blue", 1, true))
        assert.equals(open_braces, close_braces)
        local _, recount = Content.sanitize_book_css(cleaned)
        assert.equals(0, recount)
    end)
end)
