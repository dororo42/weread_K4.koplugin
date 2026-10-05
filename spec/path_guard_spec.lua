-- Unit tests for the cache-path traversal guards (2026-09-29 audit Y-1).
--
-- The audit proved the old isSafeCachePath bypassable: it validated the
-- lexically COLLAPSED shape while the callers deleted the RAW string, so a
-- corrupted book.cache_dir like "<root>/../evil" passed the prefix check
-- while the OS resolved ".." at deletion time. The fix normalizes first and
-- makes callers use the SAME normalized path.
--
-- Under test:
--   * PluginUtil.lexical_normalize — the shared pure resolver;
--   * ui/cache.lua M:isSafeCachePath — now returns the normalized path (or
--     nil); the three audit bypasses must be refused;
--   * BookStore.resolved_dir — must never hand a ".."-laden record path back
--     to callers.
--
-- NOTE: busted runs all specs in ONE Lua state; stubs follow the
-- prefetch_guard_spec.lua pattern (preload + package.loaded, restore
-- pre-existing entries at teardown).
local __SPEC_STUB_NAMES = {
    "ffi/util", "weread.lib.i18n", "weread.lib.logger", "bit",
    "weread.lib.crypto", "weread.lib.reader_state", "weread.lib.protocol",
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/pathchooser",
    "ui/uimanager", "device", "pluginshare", "ui/time", "weread.lib.scan",
    "weread.lib.footnotes", "weread.lib.foreground_barrier",
    "weread.ui.download_dialog", "weread.lib.downloader",
    "weread.lib.plugin_util", "weread.lib.book_store", "weread.ui.cache",
}
local __PREEXISTING = {}
for _, name in ipairs(__SPEC_STUB_NAMES) do
    __PREEXISTING[name] = { loaded = package.loaded[name], preload = package.preload[name] }
end
local function preload_stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = factory()
end

preload_stub("ffi/util", function()
    return { template = function(text) return text end }
end)
preload_stub("weread.lib.i18n", function()
    return { tr = function(text) return text end }
end)
preload_stub("weread.lib.logger", function()
    return {
        info = function() end, warn = function() end, err = function() end,
        scoped = function() return { info = function() end, warn = function() end, err = function() end } end,
    }
end)
preload_stub("bit", function() return {} end)
preload_stub("weread.lib.crypto", function() return {} end)
preload_stub("weread.lib.reader_state", function() return {} end)
preload_stub("weread.lib.protocol", function()
    return {
        urlencode = function(v) return tostring(v) end,
        reader_url = function() return "https://weread.qq.com/web/reader/x" end,
        is_mp_book = function(id) return tostring(id):sub(1, 7) == "MP_WXS_" end,
        normalize_cover_url = function(url) return url end,
    }
end)
preload_stub("ui/widget/buttondialog", function()
    return { new = function() return {} end }
end)
preload_stub("ui/widget/confirmbox", function()
    return { new = function(_c, opts) return opts end }
end)
preload_stub("ui/widget/pathchooser", function()
    return { new = function() return {} end }
end)
preload_stub("ui/uimanager", function()
    return {
        show = function() end, close = function() end,
        scheduleIn = function() end, unschedule = function() end,
        forceRePaint = function() end,
    }
end)
preload_stub("device", function() return {} end)
preload_stub("pluginshare", function() return {} end)
preload_stub("ui/time", function()
    local t = 1000000
    return { now = function() t = t + 1; return t end }
end)
preload_stub("weread.lib.scan", function()
    return { scan_root = function() return 0, 0 end }
end)
preload_stub("weread.lib.footnotes", function() return {} end)
preload_stub("weread.lib.foreground_barrier", function() return {} end)
preload_stub("weread.ui.download_dialog", function() return {} end)
preload_stub("weread.lib.downloader", function() return {} end)

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

-- Module under test reloads against the stubs: plugin_util and book_store
-- are the REAL implementations (the names were only reserved above so the
-- teardown can restore exactly the pre-spec state). Clear BOTH caches:
-- earlier specs (e.g. mp_images_spec) leave package.preload factories behind
-- that would otherwise serve an empty stub instead of the real module.
package.preload["weread.lib.plugin_util"] = nil
package.preload["weread.lib.book_store"] = nil
package.loaded["weread.lib.plugin_util"] = nil
package.loaded["weread.lib.book_store"] = nil
local PluginUtil = require("weread.lib.plugin_util")
local BookStore = require("weread.lib.book_store")
local CacheUI = require("weread.ui.cache")

local ROOT = "/mnt/us/koreader/data/weread/cache"

-- isSafeCachePath only reads self.settings.cache_dir; a minimal receiver
-- double exercises it without constructing the full cache-management UI.
local function guard(path)
    return CacheUI.isSafeCachePath({ settings = { cache_dir = ROOT } }, path)
end

describe("PluginUtil.lexical_normalize (audit Y-1)", function()
    teardown(__CLEAR)

    it("resolves interior .. and . segments", function()
        assert.equals("/a/b", PluginUtil.lexical_normalize("/a/./b"))
        assert.equals("/a/b", PluginUtil.lexical_normalize("/a/x/../b"))
        assert.equals("/a/b", PluginUtil.lexical_normalize("/a/b/"))
        assert.equals("/a/b/c", PluginUtil.lexical_normalize("/a/b/../b/./c"))
    end)

    it("keeps absolute paths absolute and relative paths relative", function()
        assert.equals("/a", PluginUtil.lexical_normalize("/a"))
        assert.equals("b", PluginUtil.lexical_normalize("a/../b"))
        assert.equals("", PluginUtil.lexical_normalize("."))
    end)

    it("collapses to the filesystem root without escaping it", function()
        assert.equals("/", PluginUtil.lexical_normalize("/"))
        assert.equals("/", PluginUtil.lexical_normalize("/a/.."))
        assert.equals("/c", PluginUtil.lexical_normalize("/a/b/../../c"))
    end)

    it("returns nil when .. climbs above the filesystem root", function()
        assert.is_nil(PluginUtil.lexical_normalize("/.."))
        assert.is_nil(PluginUtil.lexical_normalize("../x"))
        assert.is_nil(PluginUtil.lexical_normalize("/../x"))
    end)

    it("returns nil for non-string and empty input", function()
        assert.is_nil(PluginUtil.lexical_normalize(nil))
        assert.is_nil(PluginUtil.lexical_normalize(""))
        assert.is_nil(PluginUtil.lexical_normalize(42))
    end)
end)

describe("isSafeCachePath traversal guard (audit Y-1)", function()
    teardown(__CLEAR)

    it("accepts a normal book directory inside the root", function()
        assert.equals(ROOT .. "/bookB1", guard(ROOT .. "/bookB1"))
    end)

    it("normalizes an interior .. and returns the resolved target", function()
        -- Resolves INSIDE the root: allowed, but the caller must delete the
        -- normalized path, not the raw one.
        assert.equals(ROOT .. "/bookB2", guard(ROOT .. "/bookB1/../bookB2"))
    end)

    it("refuses the three audit bypasses", function()
        -- These returned true under the old guard while deleting outside
        -- the root after OS resolution.
        assert.is_nil(guard(ROOT .. "/../evil"))
        assert.is_nil(guard(ROOT .. "/.."))
        assert.is_nil(guard(ROOT .. "/sub/../../etc"))
    end)

    it("refuses escapes above the filesystem root and the root itself", function()
        assert.is_nil(guard("/.."))
        assert.is_nil(guard("../x"))
        assert.is_nil(guard(ROOT))
        assert.is_nil(guard("/"))
    end)

    it("refuses lookalike siblings and unrelated trees", function()
        assert.is_nil(guard(ROOT .. "-backup/bookB1"))
        assert.is_nil(guard("/mnt/other/bookB1"))
    end)

    it("refuses garbage input", function()
        assert.is_nil(guard(nil))
        assert.is_nil(guard(""))
        assert.is_nil(guard(7))
    end)
end)

describe("BookStore.resolved_dir root validation (audit Y-1)", function()
    teardown(__CLEAR)

    it("falls back to the safe per-book directory for a traversal cache_dir", function()
        local dir = BookStore.resolved_dir(
            { cache_dir = ROOT }, "B1",
            { cache_dir = ROOT .. "/../evil" })
        assert.equals(ROOT .. "/B1", dir)
    end)

    it("returns the normalized form of an interior-.. record path", function()
        local dir = BookStore.resolved_dir(
            { cache_dir = ROOT }, "B1",
            { cache_dir = ROOT .. "/B1/../B2" })
        assert.equals(ROOT .. "/B2", dir)
    end)

    it("uses the safe fallback for a book id of exactly ..", function()
        local dir = BookStore.resolved_dir({ cache_dir = ROOT }, "..", {})
        assert.equals(ROOT .. "/weread", dir)
    end)

    it("keeps a plain in-root record path verbatim", function()
        local dir = BookStore.resolved_dir(
            { cache_dir = ROOT }, "B1", { cache_dir = ROOT .. "/B1" })
        assert.equals(ROOT .. "/B1", dir)
    end)
end)

-- F-11 (2026-10-05 audit): os.rename signals failure by RETURNING (nil, msg),
-- it does not raise. The old move_dir checked pcall's first return only and
-- reported success unconditionally, making the cross-filesystem copy+delete
-- fallback dead code. Regression: when the rename fails, move_dir must NOT
-- report success. Uses the top-level CacheUI (loaded against the stubs at
-- collection time); only os.rename and the lfs handle are swapped per test.
describe("move_dir rename fallback (F-11)", function()
    local saved_rename, saved_lfs
    before_each(function()
        saved_rename = rawget(os, "rename")
        saved_lfs = package.loaded["libs/libkoreader-lfs"]
    end)
    after_each(function()
        rawset(os, "rename", saved_rename)
        package.loaded["libs/libkoreader-lfs"] = saved_lfs
    end)

    it("does not report success when os.rename fails", function()
        rawset(os, "rename", function() return nil, "cross-device link" end)
        -- lfs handle without dir(): the copy+delete fallback cannot
        -- enumerate the source, so move_dir must surface the failure
        -- (false), never the old unconditional `true`.
        package.loaded["libs/libkoreader-lfs"] = {}
        local ok, err = CacheUI.move_dir("/mem/src", "/mem/dst")
        assert.is_false(ok)
        assert.equals("cross-device link", err)
    end)

    it("still reports success when os.rename succeeds", function()
        rawset(os, "rename", function() return true end)
        assert.is_true(CacheUI.move_dir("/mem/src", "/mem/dst"))
    end)
end)
