-- Unit tests for the lipc standby guard (2026-11-12): the residue-clearing
-- entry point used at plugin init (a crash mid-download leaves powerd's
-- preventScreenSaver at 1, arming koreader#16194's freeze mode), plus the
-- set/clear pair used by the downloader.
package.preload["device"] = function()
    return { isKindle = function() return _G.__is_kindle end }
end
package.preload["weread/lib/logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.loaded["weread.lib.standby_guard"] = nil

local Guard = require("weread.lib.standby_guard")

local executed

describe("standby_guard residue clearing (2026-11-12)", function()
    before_each(function()
        executed = {}
        _G.__is_kindle = true
        os.execute = function(cmd)
            executed[#executed + 1] = cmd
            return 0
        end
    end)

    it("clears a stale preventScreenSaver=1 at init time", function()
        Guard.clearPreventScreenSaverResidue()
        assert.equals(1, #executed)
        assert.truthy(executed[1]:find("preventScreenSaver 0", 1, true))
    end)

    it("survives a lipc failure without raising", function()
        os.execute = function() error("lipc not available") end
        local ok = pcall(Guard.clearPreventScreenSaverResidue)
        assert.is_true(ok)
    end)

    it("set/clear pair issues the two lipc props in order", function()
        Guard.setPreventScreenSaver()
        Guard.clearPreventScreenSaver()
        assert.equals(2, #executed)
        assert.truthy(executed[1]:find("preventScreenSaver 1", 1, true))
        assert.truthy(executed[2]:find("preventScreenSaver 0", 1, true))
    end)
end)

describe("standby_guard device gating (2026-11-12)", function()
    before_each(function()
        executed = {}
    end)

    it("skips the lipc call on non-Kindle devices", function()
        _G.__is_kindle = false
        Guard.clearPreventScreenSaverResidue()
        Guard.setPreventScreenSaver()
        Guard.clearPreventScreenSaver()
        assert.equals(0, #executed)
    end)
end)
