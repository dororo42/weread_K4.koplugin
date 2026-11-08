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

-- Cross-repo contract (2026-11-08 audit): the suite below replaces FLAG_DIR
-- with a fake path in before_each, so it could never catch a drift in the
-- production literal. Capture it at load time and pin it here; the writer
-- side is checked by K4weread's check_marker_path.py --peer-repo.
local PRODUCTION_FLAG = OnlyMode.flag_path()

describe("weread.lib.only_mode production handshake contract", function()
    it("pins the device marker path shared with K4weread", function()
        assert.equals("/mnt/us/k4weread/launch.flag", PRODUCTION_FLAG)
    end)
end)

describe("weread.lib.only_mode", function()
    local saved_fs, saved_active, saved_dir, saved_name, saved_pending

    before_each(function()
        saved_fs = OnlyMode._fs
        saved_active = OnlyMode._session_active
        saved_dir = OnlyMode.FLAG_DIR
        saved_name = OnlyMode.FLAG_NAME
        saved_pending = OnlyMode._pending_remove
        OnlyMode._session_active = false
        OnlyMode._pending_remove = false
        OnlyMode.FLAG_DIR = "/tmp/weread-spec-fake"
        OnlyMode.FLAG_NAME = "launch.flag"
    end)

    after_each(function()
        OnlyMode._fs = saved_fs
        OnlyMode._session_active = saved_active
        OnlyMode.FLAG_DIR = saved_dir
        OnlyMode.FLAG_NAME = saved_name
        OnlyMode._pending_remove = saved_pending
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

        it("retries a failed removal on a later init", function()
            local calls, fs = fake_fs({ ["/tmp/weread-spec-fake/launch.flag"] = true })
            fs.remove = function()
                calls.remove[#calls.remove + 1] = "failed"
                return nil, "busy"
            end
            OnlyMode._fs = fs
            assert.is_true(OnlyMode.detect_and_consume())
            assert.is_true(OnlyMode._pending_remove)

            OnlyMode._fs = {
                exists = function() return false end,
                remove = function(path)
                    calls.remove[#calls.remove + 1] = path
                    return true
                end,
            }
            assert.is_true(OnlyMode.detect_and_consume())
            assert.is_false(OnlyMode._pending_remove)
            assert.equals(2, #calls.remove)
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
