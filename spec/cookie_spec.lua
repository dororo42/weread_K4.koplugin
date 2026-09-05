-- Unit tests for weread/lib/cookie.lua (pure Lua, no KOReader deps).
local Cookie = require("weread.lib.cookie")

describe("Cookie.to_header", function()
    it("sorts cookies into a header string", function()
        assert.equals("a=1; b=2", Cookie.to_header({ b = "2", a = "1" }))
    end)

    it("returns an empty string for empty input", function()
        assert.equals("", Cookie.to_header(nil))
        assert.equals("", Cookie.to_header({}))
    end)

    it("strips control characters from keys and values (S-08)", function()
        local header = Cookie.to_header({ ["wr\r\n_skey"] = "abc\r\nDEF" })
        assert.equals("wr_skey=abcDEF", header)
    end)
end)

describe("Cookie.merge_set_cookie", function()
    it("accepts wr_ cookies and honours deletion via empty value", function()
        local cookies = { wr_skey = "old" }
        Cookie.merge_set_cookie(cookies, "wr_skey=NEW; Path=/; HttpOnly")
        assert.equals("NEW", cookies.wr_skey)
        Cookie.merge_set_cookie(cookies, "wr_skey=; Path=/")
        assert.is_nil(cookies.wr_skey)
    end)

    it("ignores non-allowlisted third-party cookies", function()
        local cookies = {}
        Cookie.merge_set_cookie(cookies, "tracker=xyz; wr_vid=42")
        assert.equals("42", cookies.wr_vid)
        assert.is_nil(cookies.tracker)
    end)

    it("keeps the allowlisted third-party cookies", function()
        local cookies = {}
        Cookie.merge_set_cookie(cookies, "ptcz=abc; RK=def; pgv_pvid=ghi; other=jkl")
        assert.equals("abc", cookies.ptcz)
        assert.equals("def", cookies.RK)
        assert.equals("ghi", cookies.pgv_pvid)
        assert.is_nil(cookies.other)
    end)

    it("passes through table-form set-cookie headers", function()
        local cookies = {}
        Cookie.merge_set_cookie(cookies, { "wr_skey=one", "wr_rt=two" })
        assert.equals("one", cookies.wr_skey)
        assert.equals("two", cookies.wr_rt)
    end)
end)

describe("Cookie.has_login_cookie", function()
    it("accepts a modern wr_gid fallback", function()
        assert.is_true(Cookie.has_login_cookie({ wr_gid = "1234567" }))
        assert.is_true(Cookie.has_login_cookie({ wr_skey = "abcdefgh" }))
        assert.is_false(Cookie.has_login_cookie({ wr_skey = "short" }))
        -- nil input falls through the `and` chain to a nil return (falsy).
        assert.is_nil(Cookie.has_login_cookie(nil))
    end)
end)
