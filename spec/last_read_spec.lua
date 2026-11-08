-- spec/last_read_spec.lua
-- v9.1 (K4weread): last-read WeRead book tracking for the weread-only
-- launch mode. The plugin records the last opened WeRead book on
-- ReaderReady; the autostart reopens it directly and falls back to the
-- bookshelf when nothing is recorded or the cached file is gone.
--
-- The module is pure: settings and filesystem access are injected (receiver
-- doubles / fake fs), so this spec never touches a real filesystem — same
-- posture as only_mode_spec.

local LastRead = require("weread.lib.last_read")

describe("weread.lib.last_read", function()
    local saved_fs

    before_each(function()
        saved_fs = LastRead._fs
    end)

    after_each(function()
        LastRead._fs = saved_fs
    end)

    -- Receiver double matching the Settings surface used here
    -- (get(key) / set(key, value)) plus a fault-injection hook.
    local function fake_settings(state, opts)
        opts = opts or {}
        return {
            get = function(_self, key)
                if opts.fail_get then error("settings io surprise") end
                return state[key]
            end,
            set = function(_self, key, value)
                if opts.fail_set then error("settings io surprise") end
                state[key] = value
            end,
        }
    end

    local function fake_fs(existing)
        return {
            exists = function(path)
                return existing[path] == true
            end,
        }
    end

    describe("record", function()
        it("stores the path under the settings key", function()
            local state = {}
            local settings = fake_settings(state)
            assert.is_true(LastRead.record(settings, "/mnt/us/book.epub"))
            assert.same({ path = "/mnt/us/book.epub" }, state[LastRead.SETTINGS_KEY])
        end)

        it("rejects empty/nil paths without touching settings", function()
            local state = {}
            local settings = fake_settings(state)
            assert.is_false(LastRead.record(settings, nil))
            assert.is_false(LastRead.record(settings, ""))
            assert.is_nil(state[LastRead.SETTINGS_KEY])
        end)

        it("survives settings write failures", function()
            local settings = fake_settings({}, { fail_set = true })
            assert.is_false(LastRead.record(settings, "/mnt/us/book.epub"))
        end)
    end)

    describe("pick", function()
        it("returns the recorded path when the file exists", function()
            local settings = fake_settings({
                [LastRead.SETTINGS_KEY] = { path = "/mnt/us/book.epub" },
            })
            assert.equals("/mnt/us/book.epub",
                LastRead.pick(settings, fake_fs({ ["/mnt/us/book.epub"] = true })))
        end)

        it("returns nil when the recorded file is gone (shelf fallback)", function()
            local settings = fake_settings({
                [LastRead.SETTINGS_KEY] = { path = "/mnt/us/gone.epub" },
            })
            assert.is_nil(LastRead.pick(settings, fake_fs({})))
        end)

        it("returns nil when nothing was recorded", function()
            local settings = fake_settings({})
            assert.is_nil(LastRead.pick(settings, fake_fs({})))
        end)

        it("returns nil on corrupted settings values", function()
            local settings = fake_settings({
                [LastRead.SETTINGS_KEY] = "garbage",
            })
            assert.is_nil(LastRead.pick(settings, fake_fs({})))
        end)

        it("returns nil on empty path values", function()
            local settings = fake_settings({
                [LastRead.SETTINGS_KEY] = { path = "" },
            })
            assert.is_nil(LastRead.pick(settings, fake_fs({})))
        end)

        it("never throws on settings or fs probe failures", function()
            local settings = fake_settings({}, { fail_get = true })
            assert.has_no_errors(function()
                LastRead.pick(settings, { exists = function() error("fs") end })
            end)
            assert.is_nil(LastRead.pick(settings, { exists = function() error("fs") end }))
        end)

        it("defaults to the module fs surface when none is injected", function()
            local settings = fake_settings({})
            assert.has_no_errors(function()
                LastRead.pick(settings)
            end)
        end)
    end)
end)
