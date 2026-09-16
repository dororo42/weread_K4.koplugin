-- Unit tests for the B13 prefetch failure guard (reMarkable official-client
-- borrow: "Auto cache stopped after 3 attempts").
--
-- B13 semantics under test:
--   * N consecutive REAL prefetch failures for the same book arm a cooldown;
--     while armed, Downloader:start() suppresses automatic prefetch and
--     reports "prefetch_cooling_down" instead of issuing doomed requests.
--   * Cancelled/superseded jobs (cancelled/replaced/...) are not failures.
--   * A success resets the streak (and clears an unexpired cooldown is NOT
--     required: success can only happen when a job actually ran).
--   * Once the cooldown expires, the streak resets and automatic prefetch
--     gets a fresh chance.
--   * Manual downloads never see the guard.
--
-- NOTE: busted runs all specs in ONE Lua state; stubs follow the
-- remarkable_borrow_p1_spec.lua pattern (preload + package.loaded, restore
-- pre-existing entries at teardown).
local __SPEC_STUB_NAMES = {
    "ui/widget/confirmbox", "device", "pluginshare", "ui/uimanager",
    "weread.lib.logger", "ui/time", "ffi/util",
    "weread.lib.content", "weread.lib.foreground_barrier",
    "weread.ui.download_dialog", "weread.lib.footnotes",
    "weread.lib.i18n", "weread.lib.plugin_util", "weread.lib.protocol",
    "ffi/xml", "util", "ui/widget/container/widgetcontainer",
}
local __PREEXISTING = {}
for _, name in ipairs(__SPEC_STUB_NAMES) do
    __PREEXISTING[name] = package.loaded[name]
end
local function preload_stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = factory()
end

preload_stub("ui/widget/confirmbox", function() return {} end)
preload_stub("device", function() return {} end)
preload_stub("pluginshare", function() return {} end)
preload_stub("ui/uimanager", function()
    return {
        scheduleIn = function() end,
        unschedule = function() end,
        close = function() end,
        show = function() end,
        preventStandby = function() end,
        allowStandby = function() end,
    }
end)
preload_stub("weread.lib.logger", function()
    return {
        info = function() end, warn = function() end, err = function() end,
        scoped = function() return { info = function() end, warn = function() end, err = function() end } end,
    }
end)
preload_stub("ui/time", function()
    -- downloader only does arithmetic on time.now(); a monotonic counter is fine.
    local t = 1000000
    return { now = function() t = t + 1; return t end }
end)
preload_stub("ffi/util", function()
    return { template = function(text) return text end }
end)
preload_stub("weread.lib.content", function() return {} end)
preload_stub("weread.lib.foreground_barrier", function() return {} end)
preload_stub("weread.ui.download_dialog", function() return {} end)
preload_stub("weread.lib.footnotes", function() return {} end)
preload_stub("weread.lib.i18n", function()
    return { tr = function(text) return text end }
end)
preload_stub("weread.lib.plugin_util", function() return {} end)
preload_stub("weread.lib.protocol", function() return {} end)
preload_stub("ffi/xml", function() return {} end)
preload_stub("util", function() return {} end)
preload_stub("ui/widget/container/widgetcontainer", function() return {} end)

-- Drop cached copies of the module under test so it reloads against the stubs.
package.loaded["weread.lib.downloader"] = nil

local function __CLEAR()
    package.loaded["weread.lib.downloader"] = nil
    for name, mod in pairs(__PREEXISTING) do
        if mod ~= nil then package.loaded[name] = mod end
    end
end

local Downloader = require("weread.lib.downloader")

local function new_downloader()
    return Downloader:new({
        is_connected = function() return true end,
        require_login = function() return true end,
        settings = {
            -- nil is_cookie_configured field skips the prefetch cookie check
            get = function(_self, _key, default) return default end,
        },
    })
end

local function fake_prefetch_job(downloader, book_id, on_complete)
    return {
        prefetch = true,
        book = { book_id = book_id },
        on_complete = on_complete,
        failed = {},
        selected = {},
        chapters = {},
    }
end

describe("B13 prefetch failure guard (reMarkable borrow)", function()
    teardown(function()
        __CLEAR()
    end)

    it("arms the cooldown after three consecutive real failures", function()
        local dl = new_downloader()
        for _i = 1, 2 do
            dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), false, "HTTP 500")
        end
        assert.is_nil(dl._prefetch_fail_until)
        dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), false, "HTTP 500")
        assert.is_not_nil(dl._prefetch_fail_until)
        assert.is_true(dl._prefetch_fail_until > os.time())
    end)

    it("does not count cancelled or superseded jobs as failures", function()
        local dl = new_downloader()
        for _, reason in ipairs({ "cancelled", "replaced", "manual_download", "next_chapter_cached" }) do
            dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), false, reason)
        end
        assert.is_nil(dl._prefetch_fail_until)
        -- the streak counter itself was never armed
        assert.is_nil(dl._prefetch_fail_streak)
    end)

    it("resets the streak when a prefetch succeeds", function()
        local dl = new_downloader()
        for _i = 1, 2 do
            dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), false, "timeout")
        end
        dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), true, nil)
        dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), false, "timeout")
        assert.is_nil(dl._prefetch_fail_until)
    end)

    it("suppresses automatic prefetch while the cooldown is armed", function()
        local dl = new_downloader()
        for _i = 1, 3 do
            dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), false, "HTTP 500")
        end
        local reported, reason
        local started = dl:start(
            { book_id = "B1", title = "Book" },
            { { chapterUid = 42, title = "Chapter" } },
            "chapter",
            {
                prefetch = true,
                on_complete = function(ok, value)
                    reported = ok
                    reason = value
                end,
            })
        assert.is_false(started)
        assert.is_false(reported)
        assert.equals("prefetch_cooling_down", reason)
        assert.is_nil(dl._active_job)
    end)

    it("resets the streak once the cooldown has expired", function()
        local dl = new_downloader()
        for _i = 1, 3 do
            dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), false, "HTTP 500")
        end
        -- Simulate the cooldown fully elapsed.
        dl._prefetch_fail_until = os.time() - 1
        -- A fresh prefetch must NOT be suppressed; the guard resets the
        -- streak and start() proceeds into the state machine (which errors
        -- under these stubs -- that is fine, the guard already passed).
        local reported, reason
        pcall(function()
            dl:start(
                { book_id = "B1", title = "Book" },
                { { chapterUid = 42, title = "Chapter" } },
                "chapter",
                {
                    prefetch = true,
                    on_complete = function(ok, value)
                        reported = ok
                        reason = value
                    end,
                })
        end)
        assert.is_not_equal("prefetch_cooling_down", reason)
        assert.is_true((dl._prefetch_fail_streak or 0) < 3)
    end)

    it("never suppresses manual downloads", function()
        local dl = new_downloader()
        for _i = 1, 3 do
            dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), false, "HTTP 500")
        end
        -- Cooldown armed; a manual job must sail past the guard. It then
        -- errors deep in the stubbed state machine -- acceptable under pcall.
        local reason
        pcall(function()
            dl:start(
                { book_id = "B1", title = "Book" },
                { { chapterUid = 42, title = "Chapter" } },
                "chapter",
                {
                    on_complete = function(_ok, value) reason = value end,
                })
        end)
        assert.is_not_equal("prefetch_cooling_down", reason)
    end)

    it("scopes the failure streak per book", function()
        local dl = new_downloader()
        for _i = 1, 2 do
            dl:_notifyCompletion(fake_prefetch_job(dl, "B1", function() end), false, "HTTP 500")
        end
        -- A different book starts a fresh streak: two failures there arm nothing.
        dl:_notifyCompletion(fake_prefetch_job(dl, "B2", function() end), false, "HTTP 500")
        assert.is_nil(dl._prefetch_fail_until)
    end)
end)
