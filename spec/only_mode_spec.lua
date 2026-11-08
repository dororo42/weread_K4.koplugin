-- spec/only_mode_spec.lua
-- v9.0 (K4weread): weread-only launch mode — marker flag consume semantics.
--
-- The K4weread KUAL extension touches /mnt/us/k4weread/launch.flag before
-- starting KOReader; the first plugin instance to init must consume it
-- (read + delete) and arm a module-level session state that later instances
-- (FM -> Reader handoff inside one process) can query without the file.
-- All filesystem access goes through the injectable M._fs surface, so this
-- spec never touches a real filesystem (same posture as the mock-gateway
-- specs: the device-dependent surface is stubbed, the logic under test is
-- the pure decision/semantics layer).

local OnlyMode = require("weread.lib.only_mode")

describe("weread.lib.only_mode", function()
    local saved_fs, saved_active, saved_dir, saved_name

    before_each(function()
        saved_fs = OnlyMode._fs
        saved_active = OnlyMode._session_active
        saved_dir = OnlyMode.FLAG_DIR
        saved_name = OnlyMode.FLAG_NAME
        OnlyMode._session_active = false
        OnlyMode.FLAG_DIR = "/tmp/weread-spec-fake"
        OnlyMode.FLAG_NAME = "launch.flag"
    end)

    after_each(function()
        OnlyMode._fs = saved_fs
        OnlyMode._session_active = saved_active
        OnlyMode.FLAG_DIR = saved_dir
        OnlyMode.FLAG_NAME = saved_name
    end)

    -- Minimal fake fs: `state` is a set of existing paths; every call is
    -- recorded so specs can assert on absence of access too.
    local function fake_fs(state)
        local calls = { exists = {}, remove = {} }
        return calls, {
            exists = function(path)
                calls.exists[#calls.exists + 1] = path
                return state[path] == true
            end,
            remove = function(path)
                calls.remove[#calls.remove + 1] = path
                if state[path] ~= true then
                    return nil, "enoent"
                end
                state[path] = nil
                return true
            end,
        }
    end

    describe("flag_path", function()
        it("joins FLAG_DIR and FLAG_NAME with a single separator", function()
            assert.equals("/tmp/weread-spec-fake/launch.flag", OnlyMode.flag_path())
        end)
    end)

    describe("detect_and_consume", function()
        it("consumes a present flag, arms the session, deletes the file", function()
            local calls, fs = fake_fs({ ["/tmp/weread-spec-fake/launch.flag"] = true })
            OnlyMode._fs = fs
            assert.is_true(OnlyMode.detect_and_consume())
            assert.is_true(OnlyMode.is_active())
            assert.equals(1, #calls.remove)
            assert.equals("/tmp/weread-spec-fake/launch.flag", calls.remove[1])
        end)

        it("returns false and stays inactive when no flag exists", function()
            local calls, fs = fake_fs({})
            OnlyMode._fs = fs
            assert.is_false(OnlyMode.detect_and_consume())
            assert.is_false(OnlyMode.is_active())
            assert.equals(0, #calls.remove)
        end)

        it("is idempotent once armed: later inits do not touch the fs", function()
            local calls, fs = fake_fs({ ["/tmp/weread-spec-fake/launch.flag"] = true })
            OnlyMode._fs = fs
            assert.is_true(OnlyMode.detect_and_consume())
            assert.is_true(OnlyMode.detect_and_consume())
            -- The second call is served from module state, not the filesystem.
            assert.equals(1, #calls.exists)
            assert.equals(1, #calls.remove)
        end)

        it("arms the session even when removal fails (flag was observed)", function()
            local calls, fs = fake_fs({ ["/tmp/weread-spec-fake/launch.flag"] = true })
            fs.remove = function()
                calls.remove[#calls.remove + 1] = "boom"
                error("remove failed")
            end
            OnlyMode._fs = fs
            assert.is_true(OnlyMode.detect_and_consume())
            assert.is_true(OnlyMode.is_active())
        end)

        it("never throws when the filesystem probe errors", function()
            OnlyMode._fs = {
                exists = function() error("io surprise") end,
                remove = function() error("unreachable") end,
            }
            assert.has_no_errors(function()
                OnlyMode.detect_and_consume()
            end)
            assert.is_false(OnlyMode.is_active())
        end)
    end)

    describe("_reset", function()
        it("clears session state for independent spec runs", function()
            local _, fs = fake_fs({ ["/tmp/weread-spec-fake/launch.flag"] = true })
            OnlyMode._fs = fs
            OnlyMode.detect_and_consume()
            assert.is_true(OnlyMode.is_active())
            OnlyMode._reset()
            assert.is_false(OnlyMode.is_active())
        end)
    end)
end)
