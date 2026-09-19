-- Unit tests for the gateway-first chapter catalog (P2, 2026-09-19):
-- Content.fetch_catalog prefers the official cookie-free
-- /book/chapterinfo gateway endpoint and falls back to the web
-- chapterInfos endpoint whenever the gateway is unusable (no API key,
-- transport/API failure, or an answer with no usable chapters).
-- Response shapes come from the 2026-09-19 live gateway probes
-- (archived: .workbuddy/capture/b3gw_list_resp.json).
package.preload["bit"] = function() return {} end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        urlencode = function(v) return tostring(v) end,
        reader_url = function(book_id) return "https://weread.qq.com/web/reader/" .. tostring(book_id) end,
    }
end
package.preload["weread.lib.book_store"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            if _G.__py_dir_exists then
                return _G.__py_dir_exists(path) and "directory" or nil
            end
            return nil
        end,
        mkdir = function(path)
            if _G.__py_mkdir then
                _G.__py_mkdir(path)
                return true
            end
            os.execute('mkdir "' .. tostring(path) .. '"')
            return true
        end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end

local Content = require("weread.lib.content")

-- Gateway response shape as observed live (2026-09-19 probe, bookId 22355124).
local GW_SHAPE = {
    bookId = "B1",
    synckey = 2111346454,
    chapterUpdateTime = 1760177863,
    chapters = {
        { chapterUid = 1, chapterIdx = 0, title = "封面", wordCount = 0 },
        { chapterUid = 2, chapterIdx = 1, title = "第一章", wordCount = 1200 },
        { chapterUid = 3, chapterIdx = 2, title = "第二章", wordCount = 900 },
    },
}

local function make_client(opts)
    opts = opts or {}
    local calls = { gateway = 0, post_json = 0 }
    local client = {
        calls = calls,
        gateway = function(_self, api_name, params)
            calls.gateway = calls.gateway + 1
            calls.gateway_args = { api_name, params }
            if opts.gateway_error then
                error(opts.gateway_error)
            end
            return opts.gateway_resp
        end,
        post_json = function(_self, url, _data, _http_opts)
            calls.post_json = calls.post_json + 1
            calls.post_url = url
            return opts.web_resp
        end,
    }
    return client, calls
end

describe("Content gateway-first catalog (P2, /book/chapterinfo)", function()
    it("uses the gateway catalog and skips the web endpoint on success", function()
        local client, calls = make_client({ gateway_resp = GW_SHAPE })
        local book = { book_id = "B1" }
        local chapters = Content.fetch_catalog(client, book)
        assert.equals(1, calls.gateway)
        assert.equals("/book/chapterinfo", calls.gateway_args[1])
        assert.equals("B1", calls.gateway_args[2].bookId)
        assert.equals(0, calls.post_json)
        -- 封面 (wordCount=0) is filtered by readable_chapters
        assert.equals(2, #chapters)
        assert.equals("第一章", chapters[1].title)
        assert.equals("第二章", chapters[2].title)
        assert.equals(2, #book.chapters)
    end)

    it("falls back to the web chapterInfos endpoint when the gateway raises", function()
        local client, calls = make_client({
            gateway_error = "WeRead API key is not configured",
            web_resp = { data = { { bookId = "B1", updated = {
                { chapterUid = 9, chapterIdx = 0, title = "Web章", wordCount = 500 },
            } } } },
        })
        local book = { book_id = "B1" }
        local chapters = Content.fetch_catalog(client, book)
        assert.equals(1, calls.gateway)
        assert.equals(1, calls.post_json)
        assert.is_not_nil(calls.post_url:find("chapterInfos", 1, true))
        assert.equals("Web章", chapters[1].title)
    end)

    it("falls back when the gateway answer has no usable chapters", function()
        local client, calls = make_client({
            gateway_resp = { bookId = "B1", chapters = {} },
            web_resp = { data = { { bookId = "B1", chapters = {
                { chapterUid = 9, chapterIdx = 0, title = "Web章", wordCount = 500 },
            } } } },
        })
        local chapters = Content.fetch_catalog(client, { book_id = "B1" })
        assert.equals(1, calls.post_json)
        assert.equals("Web章", chapters[1].title)
    end)
end)
