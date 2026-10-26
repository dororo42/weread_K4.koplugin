-- Unit tests for weread/lib/strict_wifi.lua (R-1, 2026-10-26 unified
-- review v2 §五 P1). The module wraps NetworkMgr:isWifiOn so the native
-- footer glyph stops reporting "connected" when the radio is merely on
-- (K4 airplane-mode shape: radio up, no AP association — the 10/25 device
-- log scenario). The wrapper is exercised against a fake NetworkMgr double;
-- no device module is touched.
local StrictWifi = require("weread.lib.strict_wifi")

describe("strict_wifi.install (R-1)", function()
    local function make_mgr(opts)
        opts = opts or {}
        return {
            isWifiOn = function() return opts.radio ~= false end,
            sysfsInterfaceOperational = opts.operational,
            ifHasAnAddress = opts.address,
        }
    end

    it("requires operational + address on top of a live radio", function()
        local mgr = make_mgr{
            operational = function() return true end,
            address = function() return true end,
        }
        assert.is_true(StrictWifi.install(mgr))
        assert.is_true(mgr.isWifiOn(mgr))
    end)

    it("reports off when the radio is off (fast path unchanged)", function()
        local mgr = make_mgr{
            radio = false,
            operational = function() return true end,
            address = function() return true end,
        }
        StrictWifi.install(mgr)
        assert.is_false(mgr.isWifiOn(mgr))
    end)

    it("reports off when the interface is not operational (10/25 shape)", function()
        -- radio on, wlan0 exists but operstate is down/no-carrier: the
        -- exact "图标恒显已连接" lie the airplane segment produced.
        local mgr = make_mgr{
            operational = function() return false end,
            address = function() return true end,
        }
        StrictWifi.install(mgr)
        assert.is_false(mgr.isWifiOn(mgr))
    end)

    it("reports off when the interface carries no address", function()
        local mgr = make_mgr{
            operational = function() return true end,
            address = function() return false end,
        }
        StrictWifi.install(mgr)
        assert.is_false(mgr.isWifiOn(mgr))
    end)

    it("degrades to radio-only semantics when a probe is missing", function()
        -- hosts without the KOReader primitives keep stock behavior — the
        -- wrapper must never invent a stricter-off state than the stock
        -- code would show.
        local mgr = make_mgr{}
        StrictWifi.install(mgr)
        assert.is_true(mgr.isWifiOn(mgr))
    end)

    it("degrades to radio-only semantics when a probe errors", function()
        local mgr = make_mgr{
            operational = function() error("sysfs read failed") end,
            address = function() return true end,
        }
        StrictWifi.install(mgr)
        assert.is_true(mgr.isWifiOn(mgr))
    end)

    it("is idempotent and does not double-wrap", function()
        local mgr = make_mgr{
            operational = function() return true end,
            address = function() return true end,
        }
        assert.is_true(StrictWifi.install(mgr))
        local wrapped = mgr.isWifiOn
        assert.is_true(StrictWifi.install(mgr))
        assert.equals(wrapped, mgr.isWifiOn)
    end)

    it("rejects an unexpected NetworkMgr surface without touching it", function()
        assert.is_false(StrictWifi.install(nil))
        assert.is_false(StrictWifi.install({ nope = true }))
        local mgr = { nope = true }
        StrictWifi.install(mgr)
        assert.is_nil(mgr._weread_strict_wifi)
    end)
end)
