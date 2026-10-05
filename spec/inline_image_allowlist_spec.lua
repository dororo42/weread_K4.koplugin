-- Unit tests for the chapter inline-image host allowlist (2026-09-29 audit
-- P1-6). Content.download_remote_images used to fetch ANY http(s) src found
-- in a book chapter's XHTML — a poisoned book source could turn e-readers
-- into arbitrary fetchers. The allowlist anchors to WeRead-operated hosts;
-- untrusted URLs keep their original src (same outcome as a failed download)
-- and are logged.
--
-- The MP-article channel (download_mp_images, upstream PR #132) has its own
-- anchored allowlist, covered in mp_images_spec.lua.
--
-- NOTE: busted runs all specs in ONE Lua state; stubs follow the
-- prefetch_guard_spec.lua pattern (preload + package.loaded, restore
-- pre-existing entries at teardown).
local __SPEC_STUB_NAMES = {
    "bit", "weread.lib.crypto", "weread.lib.reader_state",
    "weread.lib.protocol", "weread.lib.book_store", "libs/libkoreader-lfs",
    "weread.lib.i18n", "ffi/util", "weread.lib.logger",
    "weread.lib.plugin_util", "weread.lib.content",
}
local __PREEXISTING = {}
for _, name in ipairs(__SPEC_STUB_NAMES) do
    __PREEXISTING[name] = { loaded = package.loaded[name], preload = package.preload[name] }
end
local function preload_stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = factory()
end

preload_stub("bit", function() return {} end)
preload_stub("weread.lib.crypto", function() return {} end)
preload_stub("weread.lib.reader_state", function() return {} end)
preload_stub("weread.lib.protocol", function() return {} end)
-- download_remote_images never writes files (spooling is the caller's job),
-- so a no-op lfs stub is enough.
preload_stub("libs/libkoreader-lfs", function()
    return { attributes = function() return nil end, mkdir = function() return true end }
end)
preload_stub("weread.lib.i18n", function()
    return { tr = function(text) return text end }
end)
preload_stub("ffi/util", function()
    return { template = function(text) return text end }
end)
preload_stub("weread.lib.logger", function()
    return {
        info = function() end, warn = function() end, err = function() end,
        scoped = function() return { info = function() end, warn = function() end, err = function() end } end,
    }
end)

local function __CLEAR()
    for name, saved in pairs(__PREEXISTING) do
        if saved.loaded ~= nil then
            package.loaded[name] = saved.loaded
        else
            package.loaded[name] = nil
        end
        if saved.preload ~= nil then
            package.preload[name] = saved.preload
        else
            package.preload[name] = nil
        end
    end
end

package.loaded["weread.lib.plugin_util"] = nil
package.loaded["weread.lib.content"] = nil
local Content = require("weread.lib.content")

-- Fake PNG payload: magic bytes so media_type_for detects image/png. Use
-- decimal escapes only — Lua 5.1 (CI) has no \x escape.
local PNG = "\137PNG\r\n\026\n" .. string.rep("x", 64)

describe("Content.is_trusted_image_url host anchoring (audit P1-6)", function()
    teardown(__CLEAR)

    it("accepts WeRead-operated hosts over http(s)", function()
        assert.equals(true, Content.is_trusted_image_url("https://weread.qq.com/a.png"))
        assert.equals(true, Content.is_trusted_image_url("https://res.weread.qq.com/wrepub/x.jpg"))
        assert.equals(true, Content.is_trusted_image_url("http://p3.weread.qq.com/img.gif"))
        assert.equals(true, Content.is_trusted_image_url("https://mmbiz.qpic.cn/m.png"))
        assert.equals(true, Content.is_trusted_image_url("https://mmbiz.qlogo.cn/n.png"))
    end)

    it("accepts protocol-relative URLs on trusted hosts", function()
        assert.equals(true, Content.is_trusted_image_url("//res.weread.qq.com/x.png"))
    end)

    it("rejects lookalike hosts and non-image URLs", function()
        -- Prefix-spoofing must fail: the host must END at the suffix.
        assert.equals(false, Content.is_trusted_image_url("https://weread.qq.com.evil.com/a.png"))
        assert.equals(false, Content.is_trusted_image_url("https://evil.com/?x=weread.qq.com"))
        assert.equals(false, Content.is_trusted_image_url("//evil.com/?x=mmbiz.qpic.cn"))
        assert.equals(false, Content.is_trusted_image_url("https://mmbiz.qpic.cn.evil.com/a.png"))
        -- Other schemes and relative paths are not fetchable images.
        assert.equals(false, Content.is_trusted_image_url("ftp://weread.qq.com/a.png"))
        assert.equals(false, Content.is_trusted_image_url("images/local.png"))
        assert.equals(false, Content.is_trusted_image_url(nil))
    end)
end)

describe("Content.download_remote_images allowlist enforcement", function()
    teardown(__CLEAR)

    it("downloads and rewrites images on trusted hosts", function()
        local fetched = {}
        local client = {
            get_binary = function(_self, url)
                fetched[#fetched + 1] = url
                return PNG
            end,
        }
        local body = '<p><img src="https://res.weread.qq.com/wrepub/a.png"/></p>'
        local out, assets = Content.download_remote_images(client, body, {}, nil)
        assert.equals(1, #fetched)
        assert.equals(1, #assets)
        assert.equals("images/a.png", assets[1].href)
        assert.is_not_nil(out:find('src="../images/a%.png"'))
    end)

    it("never fetches untrusted hosts and keeps the original src", function()
        local fetches = 0
        local client = {
            get_binary = function()
                fetches = fetches + 1
                return PNG
            end,
        }
        local body = '<p><img src="https://example.com/pic.png"/></p>'
        local out, assets = Content.download_remote_images(client, body, {}, nil)
        assert.equals(0, fetches)
        assert.equals(0, #assets)
        assert.is_not_nil(out:find('src="https://example%.com/pic%.png"'))
    end)

    it("skips untrusted hosts in the progress total as well", function()
        -- img_total counts only fetchable (allowlisted) images, so the
        -- progress callback sees the real attempt count.
        local client = { get_binary = function() return PNG end }
        local body = '<p><img src="https://example.com/a.png"/>'
            .. '<img src="https://weread.qq.com/b.png"/></p>'
        local seen_total
        Content.download_remote_images(client, body, {}, function(_i, total)
            seen_total = total
        end)
        assert.equals(1, seen_total)
    end)

    it("keeps a mixed chapter intact: trusted fetched, untrusted untouched", function()
        local client = {
            get_binary = function(_self, url)
                return PNG
            end,
        }
        local body = '<p><img src="https://weread.qq.com/good.png"/>'
            .. '<img src="https://tracker.example/pixel.png"/></p>'
        local out, assets = Content.download_remote_images(client, body, {}, nil)
        assert.equals(1, #assets)
        assert.is_not_nil(out:find('src="../images/good%.png"'))
        assert.is_not_nil(out:find('src="https://tracker%.example/pixel%.png"'))
    end)
end)
