-- Busted port of the upstream PR #133 regression suite (spec/footnotes_spec.lua
-- in finlater/weread.koplugin v1.4.0, the +124-line block). K4 adaptations:
--   * transform_chapter takes a trailing `mode` argument — the page mode
--     renders the same <aside epub:type="footnote"> markup the upstream
--     assertions expect, so these cases pass "page".
--   * The upstream CSS-shape assertions (FOOTNOTES_CSS / get_css / POPUP_CSS)
--     are not ported: the K4 fork ships a two-mode CSS surface
--     (footnote_css_for / FOOTNOTES_PAGE_CSS / FOOTNOTES_CHAPTER_CSS).
--   * A K4-specific case pins the chapter-mode plain-div rendering.
local Footnotes = require("weread.lib.footnotes")

-- Plain-find occurrence counter: keeps literal data out of Lua patterns.
local function count_occurrences(haystack, needle)
    local count, pos = 0, 1
    while true do
        local at = haystack:find(needle, pos, true)
        if not at then return count end
        count = count + 1
        pos = at + #needle
    end
end

local chapter = { chapterUid = "101", chapterIdx = 1, files = { "Text/chapter1.xhtml" } }

describe("Footnotes definition collection (upstream PR #133)", function()
    it("indexes the real note under a chapter-root wrapper without poisoning", function()
        -- Regression: a chapter-root wrapper block spanning nearly the whole
        -- chapter used to index every descendant anchor with the entire
        -- flattened chapter (both dual-language variants concatenated) as the
        -- note text.
        local padding_unit = "這是用來模擬整章長度的填充正文段落。"
        local padding = padding_unit:rep(260)
        local poisoned_html = [[
<html><body><div id="root">
<h2 class="wr-traditional">第一章</h2><h2 class="wr-simplified">第一章</h2>
<p class="wr-traditional">這是正文內容。<a href="#fn_1">1</a></p>
<p class="wr-simplified">这是正文内容。</p>
<p class="wr-traditional">]] .. padding .. [[</p>
<a id="fn_1"></a><p>譯註：這是真正的注釋。</p>
</div></body></html>
]]
        local scan = Footnotes.scan_chapter(poisoned_html, chapter)
        assert.is_not_nil(scan.definitions["fn_1"])
        assert.equals("譯註：這是真正的注釋。", scan.definitions["fn_1"].text)
        local body, stats = Footnotes.transform_chapter(
            poisoned_html, scan,
            Footnotes.build_book_index({ ["101"] = scan }, { chapter }), "page")
        assert.equals(1, stats.converted)
        assert.equals(0, stats.unresolved)
        assert.equals(1, select(2, body:gsub('class="wr%-book%-footnote"', "")))
        local notes = body:match('<div class="wr%-footnotes">.*')
        assert.is_not_nil(notes)
        assert.is_not_nil(notes:find("譯註：這是真正的注釋。", 1, true))
        assert.is_nil(notes:find(padding_unit, 1, true))
        assert.equals(1, count_occurrences(body, padding))
    end)

    it("replaces an oversized ancestor capture with the shorter direct capture", function()
        -- Shortest-wins: when an oversized-but-legitimate ancestor capture is
        -- recorded first, the smaller direct capture must replace it.
        local filler = "補充背景說明文字。"
        local wrapped_html = "<aside>"
            .. filler:rep(30) .. '<p id="short-note">真注釋</p>' .. filler:rep(30)
            .. "</aside>"
        local scan = Footnotes.scan_chapter(wrapped_html, chapter)
        assert.is_not_nil(scan.definitions["short-note"])
        assert.equals("真注釋", scan.definitions["short-note"].text)
    end)

    it("keeps a long but legitimate note below the size cap intact", function()
        local long_text = string.rep("這是一條很長但完全真實的注釋內容。", 100)
        local scan = Footnotes.scan_chapter(
            '<p id="long-note">' .. long_text .. "</p>", chapter)
        assert.is_not_nil(scan.definitions["long-note"])
        assert.equals(long_text, scan.definitions["long-note"].text)
    end)

    it("does not let a backlink arrow sharing the note id poison the definition", function()
        -- Regression: a backlink arrow inside an element sharing the note
        -- target's id used to poison the definition; with shortest-wins the
        -- arrow glyph is now rejected by the symbol-only gate instead.
        local arrow_html = [[<li id="fn_9">這是完整的注釋正文內容。<a id="fn_9" href="#ref_9">↩</a></li>]]
        local arrow_doc = [[<p>正文<a class="noteref" href="#fn_9"><sup>[9]</sup></a></p>]] .. arrow_html
        local scan = Footnotes.scan_chapter(arrow_doc, chapter)
        assert.is_not_nil(scan.definitions["fn_9"])
        -- The stored text is the enclosing li capture; strip_tags leaves the
        -- trailing return glyph in place, but the definition must never
        -- collapse to it.
        assert.equals("這是完整的注釋正文內容。 ↩", scan.definitions["fn_9"].text)
        local body, stats = Footnotes.transform_chapter(
            arrow_doc, scan,
            Footnotes.build_book_index({ ["101"] = scan }, { chapter }), "page")
        assert.equals(1, stats.converted)
        assert.equals(0, stats.unresolved)
        assert.equals(true, Footnotes.validate(body))
        local aside = body:match(
            'class="wr%-book%-footnote".-<a href="#wrfnref%-101%-1"[^>]*>%[9%]</a>(.-)</p>')
        assert.is_not_nil(aside)
        assert.is_not_nil(aside:find("這是完整的注釋正文內容。", 1, true))
        assert.is_nil(aside:match("^%s*↩%s*$"))
    end)

    it("keeps notes written only in kana, hangul, Cyrillic or astral CJK", function()
        -- Regression: notes in non-ASCII scripts must never be mistaken for
        -- pure symbols; any real text codepoint keeps the candidate.
        local scripts_html = '<p id="kana-note">これは日本語の脚注です。</p>'
            .. '<p id="hangul-note">한국어 각주입니다.</p>'
            .. '<p id="cyrillic-note">Это сноска на русском языке.</p>'
            .. '<p id="extb-note">𠀀𠀁 rare CJK extension footnote.</p>'
            .. '<p id="mixed-note">①これは注釈本体。</p>'
        local scan = Footnotes.scan_chapter(scripts_html, chapter)
        for _, anchor in ipairs({ "kana-note", "hangul-note", "cyrillic-note",
            "extb-note", "mixed-note" }) do
            assert.is_not_nil(scan.definitions[anchor])
        end
        assert.equals("これは日本語の脚注です。", scan.definitions["kana-note"].text)
        assert.equals("①これは注釈本体。", scan.definitions["mixed-note"].text)
    end)

    it("rejects symbol-only candidates outright", function()
        -- Backlink arrows and their variation selectors, enclosed numbers,
        -- CJK/Latin-1 punctuation: none of these can be a definition.
        local glyph_html = '<p id="glyph-arrow">↩</p><p id="glyph-arrow-vs">↩️</p>'
            .. '<p id="glyph-left">←</p><p id="glyph-hook">⤴</p>'
            .. '<p id="glyph-enclosed">①</p><p id="glyph-cjk-punct">。</p>'
            .. '<p id="glyph-latin1">«»</p><p id="glyph-dash">……</p>'
        local scan = Footnotes.scan_chapter(glyph_html, chapter)
        for _, anchor in ipairs({ "glyph-arrow", "glyph-arrow-vs", "glyph-left",
            "glyph-hook", "glyph-enclosed", "glyph-cjk-punct", "glyph-latin1",
            "glyph-dash" }) do
            assert.is_nil(scan.definitions[anchor])
        end
    end)

    it("renders chapter-mode notes as plain divs (K4 two-mode rendering)", function()
        local html = [[
<p>正文<a epub:type="noteref" href="#note-1"><sup>[1]</sup></a></p>
<aside id="note-1"><p>[1] 同章脚注内容</p></aside>
]]
        local scan = Footnotes.scan_chapter(html, chapter)
        local body, stats = Footnotes.transform_chapter(
            html, scan,
            Footnotes.build_book_index({ ["101"] = scan }, { chapter }), "chapter")
        assert.equals(1, stats.converted)
        -- Chapter mode renders plain <div> blocks (no epub:type="footnote")
        -- so CREngine keeps them in the chapter flow (K4 default).
        assert.is_not_nil(body:find('<div id="wrfn-101-1" class="wr-book-footnote">', 1, true))
        assert.is_nil(body:find('epub:type="footnote"', 1, true))
    end)
end)
