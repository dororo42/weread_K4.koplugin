-- Busted port of the essential cases from the upstream PR #132 regression
-- suite (spec/mp_article_images_spec.lua in finlater/weread.koplugin v1.4.0),
-- adapted to the K4 fork's single-file HTML + sibling assets-directory
-- layout. Covers: URL allowlist anchoring, streaming write-through, the
-- per-image size cap, and the failure fallback (original src kept).
package.preload["bit"] = function() return {} end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.book_store"] = function() return {} end
-- PluginUtil.mkdirs walks with lfs; under the lupa harness the runner injects
-- __py_dir_exists/__py_mkdir (real filesystem semantics; lupa wraps Python
-- callables as userdata, hence the non-nil check). On real busted/CI the
-- stub falls back to os.execute("mkdir ...") for the single missing level
-- below the existing TEMP parent.
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

local function temp_dir()
    local base = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    -- Normalize separators: mkdirs walks POSIX-style segments.
    base = base:gsub("\\", "/")
    return (base:gsub("/+$", "")) .. "/weread_mp_images_spec"
end

-- Fake PNG payload: magic bytes so media_type_for detects image/png.
local PNG = "\137PNG\r\n\x1a\n" .. string.rep("x", 128)

describe("Content.is_mp_image_url anchoring (upstream PR #132)", function()
    it("accepts the two WeRead image hosts over http(s)", function()
        assert.equals(true, Content.is_mp_image_url("https://mmbiz.qpic.cn/a.png"))
        assert.equals(true, Content.is_mp_image_url("http://mmbiz.qlogo.cn/b.png"))
    end)

    it("accepts protocol-relative WeRead URLs", function()
        assert.equals(true, Content.is_mp_image_url("//mmbiz.qpic.cn/c.png"))
    end)

    it("rejects lookalike hosts and non-image URLs", function()
        -- The old unanchored match accepted these.
        assert.equals(false, Content.is_mp_image_url("https://evil.com/?x=mmbiz.qpic.cn"))
        assert.equals(false, Content.is_mp_image_url("//evil.com/?x=mmbiz.qpic.cn"))
        assert.equals(false, Content.is_mp_image_url("https://mmbiz.qpic.cn.evil.com/a.png"))
        -- Relative paths and other schemes are not article images.
        assert.equals(false, Content.is_mp_image_url("images/local.png"))
        assert.equals(false, Content.is_mp_image_url("ftp://mmbiz.qpic.cn/a.png"))
        assert.equals(false, Content.is_mp_image_url(nil))
    end)
end)

describe("Content.download_mp_images streaming (upstream PR #132)", function()
    -- Fake PNG payload served by the stub client; each case builds its own
    -- stub so failure injection stays local.

    it("writes images to the assets directory and references them relatively", function()
        local client = { get_binary = function() return PNG end }
        local dir = temp_dir()
        local body = '<p><img src="https://mmbiz.qpic.cn/a.png"/><img src="//mmbiz.qpic.cn/b.jpg"/></p>'
        local out, written = Content.download_mp_images(client, body, nil, dir)
        assert.equals(2, #written)
        assert.is_not_nil(out:find('src="weread_mp_images_spec/img1.png"', 1, true))
        assert.is_not_nil(out:find('src="weread_mp_images_spec/img2.png"', 1, true))
        -- Each file must exist on disk with the received bytes (streamed
        -- write-through, not base64 inlining).
        for _, asset in ipairs(written) do
            local f = io.open(asset.path, "rb")
            assert.is_not_nil(f)
            local data = f:read("*a")
            f:close()
            assert.equals(PNG, data)
            os.remove(asset.path)
        end
        assert.is_nil(out:find("data:image", 1, true))
    end)

    it("keeps the original src when the download fails", function()
        local client = { get_binary = function() error("offline") end }
        local body = '<p><img src="https://mmbiz.qpic.cn/lost.png"/></p>'
        local out = Content.download_mp_images(client, body, nil, temp_dir())
        assert.is_not_nil(out:find('src="https://mmbiz%.qpic%.cn/lost%.png"'))
    end)

    it("drops images exceeding the per-image size cap", function()
        local oversized = PNG .. string.rep("x", 64 * 1024 * 1024)
        local client = { get_binary = function() return oversized end }
        local body = '<p><img src="https://mmbiz.qpic.cn/huge.png"/></p>'
        local out, written = Content.download_mp_images(client, body, nil, temp_dir())
        assert.equals(0, #written)
        assert.is_not_nil(out:find('src="https://mmbiz%.qpic%.cn/huge%.png"'))
    end)

    it("ignores non-WeRead image URLs entirely", function()
        local client = { get_binary = function() return PNG end }
        local body = '<p><img src="https://example.com/pic.png"/></p>'
        local out, written = Content.download_mp_images(client, body, nil, temp_dir())
        assert.equals(0, #written)
        assert.is_not_nil(out:find('src="https://example%.com/pic%.png"'))
    end)
end)
