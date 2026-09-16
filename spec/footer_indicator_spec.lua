-- Unit tests for weread/ui/footer_indicator.lua: the glue that toggles
-- KOReader's built-in ReaderFooter "wifi_status" item from the WeRead menu.
-- KOReader's ReaderFooter is replaced by an in-memory double that records
-- the call sequence, and G_reader_settings / readerfooter.default_settings /
-- the device capability module are stubbed. Focus: state mutation, the
-- refresh bookkeeping contract (mirror of readerfooter.lua's own toggle
-- callback), the FileManager (no-live-footer) store path, and the computed
-- mode position (device gates + custom order, v5.7.1 fix).
package.preload["apps/reader/modules/readerfooter"] = function()
    return {
        default_settings = {
            disable_progress_bar = false,
            all_at_once = false,
            page_progress = true,
            time = true,
            pages_left = true,
            percentage = true,
            battery = true,
            wifi_status = false,
            item_prefix = "icons",
        },
    }
end

local FI = require("weread.ui.footer_indicator")

describe("footer_indicator", function()
    local store

    before_each(function()
        store = {
            data = {},
            flushed = 0,
            readSetting = function(self, key, default)
                local value = self.data[key]
                if value == nil then return default end
                return value
            end,
            saveSetting = function(self, key, value)
                self.data[key] = value
            end,
            flush = function(self)
                self.flushed = self.flushed + 1
            end,
        }
        _G.G_reader_settings = store
        -- Default to the K4 device shape for every test: busted collects all
        -- spec files in one Lua state first, so other files' top-level
        -- "device" stubs may already be cached here. Depending on "no device
        -- module" would make device_supports() see an empty table and gate
        -- wifi_status away, flipping every position assertion. Tests that
        -- need a different shape (or the moduleless fallback) override or
        -- clear this stub explicitly.
        package.preload["device"] = function()
            return {
                hasFastWifiStatusQuery = function() return true end,
                hasBattery = function() return true end,
                hasFrontlight = function() return false end,
                hasNaturalLight = function() return false end,
            }
        end
        package.loaded["device"] = nil
    end)

    after_each(function()
        _G.G_reader_settings = nil
        package.loaded["device"] = nil
        package.preload["device"] = nil
    end)

    -- Stub the KOReader device abstraction. K4 shape: wifi query + battery
    -- available, no frontlight / natural light (mirrors device.lua v2026.07.1
    -- Kindle base + Kindle4 block).
    local function stub_device(opts)
        opts = opts or {}
        package.preload["device"] = function()
            return {
                hasFastWifiStatusQuery = function()
                    return opts.wifi ~= false
                end,
                hasBattery = function()
                    return opts.battery ~= false
                end,
                hasFrontlight = function()
                    return opts.frontlight == true
                end,
                hasNaturalLight = function()
                    return opts.natural_light == true
                end,
            }
        end
        package.loaded["device"] = nil
    end

    -- ReaderFooter double. set_has_no_mode mirrors the real contract:
    -- returns the first enabled mode number, sets has_no_mode accordingly.
    local function make_footer(opts)
        opts = opts or {}
        local footer = {
            settings = opts.settings
                or { wifi_status = false, all_at_once = true, page_progress = true },
            has_no_mode = opts.has_no_mode or false,
            mode = opts.mode or 1,
            mode_list = { off = 0, page_progress = 1, wifi_status = 11 },
            textGeneratorMap = { empty = "EMPTY_GEN" },
            footer_text = { height = 20 },
            calls = {},
        }
        -- mirrors readerfooter.lua's MODE order (v2026.07.1) so the
        -- "first enabled mode number" contract is faithful
        local MODE_INDEX = {
            "page_progress", "pages_left_book", "time", "pages_left",
            "battery", "percentage", "book_time_to_read",
            "chapter_time_to_read", "frontlight", "mem_usage", "wifi_status",
        }
        footer.set_has_no_mode = function(self)
            table.insert(self.calls, "set_has_no_mode")
            for i, key in ipairs(MODE_INDEX) do
                if self.settings[key] == true then
                    self.has_no_mode = false
                    return i
                end
            end
            self.has_no_mode = true
            return nil
        end
        footer.updateFooterTextGenerator = function(self)
            table.insert(self.calls, "updateFooterTextGenerator")
            return true
        end
        footer.refreshFooter = function(self, refresh, signal)
            table.insert(self.calls, "refreshFooter:" .. tostring(refresh) .. ":" .. tostring(signal))
        end
        footer.rescheduleFooterAutoRefreshIfNeeded = function(self)
            table.insert(self.calls, "reschedule")
        end
        footer.applyFooterMode = function(self, mode)
            table.insert(self.calls, "applyFooterMode")
            if mode ~= nil then self.mode = mode end
        end
        return footer
    end

    describe("resolve_footer", function()
        it("returns the live footer in a ReaderUI context", function()
            local footer = make_footer()
            assert.equals(footer, FI.resolve_footer({ view = { footer = footer } }))
        end)

        it("returns nil outside ReaderUI (FileManager, no view/footer)", function()
            assert.is_nil(FI.resolve_footer(nil))
            assert.is_nil(FI.resolve_footer({}))
            assert.is_nil(FI.resolve_footer({ view = {} }))
            assert.is_nil(FI.resolve_footer({ view = { footer = { settings = nil } } }))
        end)
    end)

    describe("read_enabled", function()
        it("reads the live footer state first", function()
            local footer = make_footer({ settings = { wifi_status = true } })
            assert.is_true(FI.read_enabled({ view = { footer = footer } }))
            footer.settings.wifi_status = false
            assert.is_false(FI.read_enabled({ view = { footer = footer } }))
        end)

        it("falls back to the global store without a footer", function()
            store.data.footer = { wifi_status = true }
            assert.is_true(FI.read_enabled(nil))
            store.data.footer = { wifi_status = false }
            assert.is_false(FI.read_enabled(nil))
        end)

        it("returns false when neither footer nor store exist", function()
            assert.is_false(FI.read_enabled(nil))
        end)
    end)

    describe("apply_to_footer", function()
        it("rejects invalid footers", function()
            assert.is_false(FI.apply_to_footer(nil, true))
            assert.is_false(FI.apply_to_footer({}, true))
        end)

        it("enables with the coexist collapse and a pre-state snapshot", function()
            local footer = make_footer()
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_true(footer.settings.wifi_status)
            -- Plan A coexist: page progress survives next to the icon, and
            -- the user's pre-A item mix rides out in the backup key
            assert.is_true(footer.settings.all_at_once)
            assert.is_true(footer.settings.page_progress)
            assert.is_table(store.data.footer_pre_wifiicon_backup)
            -- the persisted mode points at the COMPUTED wifi position
            -- (10 on a frontlight-less K4), not the MODE value 11
            assert.equals(10, footer.mode)
            assert.equals(10, store.data.reader_footer_mode)
            -- native bookkeeping first, then the coexist repaint; the Plan A
            -- block ends applyFooterMode -> refreshFooter(true, true) and
            -- does NOT reschedule again
            assert.equals("updateFooterTextGenerator", footer.calls[2])
            assert.equals("applyFooterMode", footer.calls[#footer.calls - 1])
            assert.equals("refreshFooter:true:true", footer.calls[#footer.calls])
        end)

        it("enables from a no-mode footer and restores a mode (signal path)", function()
            local footer = make_footer({
                settings = { wifi_status = false, all_at_once = true },
                has_no_mode = true,
                mode = 0,
            })
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_false(footer.has_no_mode)
            -- transition branch restores a displayable mode first, then the
            -- coexist takeover re-points it at the computed wifi position
            assert.equals(10, footer.mode)
            assert.is_true(footer.settings.wifi_status)
            assert.is_table(store.data.footer_pre_wifiicon_backup)
            -- native order: set_has_no_mode, applyFooterMode + persist,
            -- updateFooterTextGenerator, refreshFooter(true, true), reschedule
            assert.equals("applyFooterMode", footer.calls[2])
            assert.equals("updateFooterTextGenerator", footer.calls[3])
            assert.equals("refreshFooter:true:true", footer.calls[4])
            assert.equals(10, store.data.reader_footer_mode)
        end)

        it("collapses the footer when the last enabled item is disabled", function()
            local footer = make_footer({
                settings = { wifi_status = true, all_at_once = true },
                has_no_mode = false,
            })
            assert.is_true(FI.apply_to_footer(footer, false))
            assert.is_false(footer.settings.wifi_status)
            assert.is_true(footer.has_no_mode)
            assert.equals(0, footer.footer_text.height)
            assert.equals("EMPTY_GEN", footer.genFooterText)
            assert.equals(0, footer.mode)
            -- native behavior: the all_at_once branch also rebuilds the
            -- generator, so the repaint carries should_update=true
            assert.equals("refreshFooter:true:true", footer.calls[#footer.calls - 1])
            assert.equals("reschedule", footer.calls[#footer.calls])
        end)

        it("disables and rebuilds the generator with other items left", function()
            local footer = make_footer({
                settings = { wifi_status = true, all_at_once = true, page_progress = true },
            })
            assert.is_true(FI.apply_to_footer(footer, false))
            assert.is_false(footer.settings.wifi_status)
            assert.is_false(footer.has_no_mode)
            assert.equals("refreshFooter:true:false", footer.calls[3])
        end)

        it("switches mode when the current single mode (wifi) is disabled", function()
            local footer = make_footer({
                settings = { wifi_status = true, all_at_once = false, page_progress = true },
                mode = 11,
            })
            assert.is_true(FI.apply_to_footer(footer, false))
            assert.equals(1, footer.mode)
            assert.is_true(footer.settings.wifi_status == false)
            assert.equals("applyFooterMode", footer.calls[2])
            assert.equals(1, store.data.reader_footer_mode)
            assert.equals("refreshFooter:true:false", footer.calls[#footer.calls - 1])
        end)

        it("collapses a single-mode footer to coexist (Plan A replaces the takeover)", function()
            local footer = make_footer({
                settings = { wifi_status = false, all_at_once = false, page_progress = true },
                mode = 1,
            })
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_true(footer.settings.wifi_status)
            -- the v5.7 single-slot pass runs first (non-touch K4 cannot cycle),
            -- then Plan A re-points the persisted mode at the computed spot
            assert.is_true(footer.settings.all_at_once)
            assert.is_table(store.data.footer_pre_wifiicon_backup)
            assert.equals(10, footer.mode)
            assert.equals(10, store.data.reader_footer_mode)
            -- Plan A block tail: applyFooterMode -> refreshFooter(true, true)
            assert.equals("applyFooterMode", footer.calls[#footer.calls - 1])
            assert.equals("refreshFooter:true:true", footer.calls[#footer.calls])
        end)

        it("keeps the legacy single-mode takeover when a snapshot is impossible", function()
            -- a store without saveSetting cannot hold a backup: collapsing
            -- would be lossy, so the v5.7 single-mode contract must run
            _G.G_reader_settings = {
                data = {},
                readSetting = function(self, key, default)
                    local value = self.data[key]
                    if value == nil then return default end
                    return value
                end,
            }
            local footer = make_footer({
                settings = { wifi_status = false, all_at_once = false, page_progress = true },
                mode = 1,
            })
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_false(footer.settings.all_at_once)
            assert.equals(11, footer.mode)
            assert.is_nil(store.data.footer_pre_wifiicon_backup)
        end)

        it("restores the original item mix and mode on disable (round trip)", function()
            local footer = make_footer({
                settings = {
                    wifi_status = false, all_at_once = false,
                    page_progress = true, time = true,
                },
                mode = 1,
            })
            store.data.footer = { wifi_status = false, all_at_once = false, page_progress = true, time = true }
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_true(footer.settings.all_at_once) -- collapsed
            assert.is_true(FI.apply_to_footer(footer, false))
            -- verbatim restore on the live footer settings table
            assert.is_false(footer.settings.wifi_status)
            assert.is_false(footer.settings.all_at_once)
            assert.is_true(footer.settings.time)
            -- the mode pointer left the coexist wifi position
            assert.equals(1, footer.mode)
            -- backup consumed, store back to the pre-A table
            assert.is_nil(store.data.footer_pre_wifiicon_backup)
            assert.is_true(store.data.footer.time)
        end)

        it("enables from a no-mode footer in single mode via the transition branch", function()
            local footer = make_footer({
                settings = { wifi_status = false, all_at_once = false },
                has_no_mode = true,
                mode = 0,
            })
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_false(footer.has_no_mode)
            -- wifi is the only enabled item, so the native first-enabled
            -- restore lands on it (mode 11) before the coexist collapse
            -- re-points the persisted mode at the computed position 10
            assert.equals(10, footer.mode)
            assert.equals(10, store.data.reader_footer_mode)
            -- Plan A block tail: applyFooterMode -> refreshFooter(true, true)
            assert.equals("applyFooterMode", footer.calls[#footer.calls - 1])
            assert.equals("refreshFooter:true:true", footer.calls[#footer.calls])
        end)

        it("does not repaint when a disabled non-current single mode is toggled", function()
            -- disable while the footer already shows something else and the
            -- icon was on: only bookkeeping, the native quiet path
            local footer = make_footer({
                settings = { wifi_status = true, all_at_once = false, page_progress = true },
                mode = 1,
            })
            assert.is_true(FI.apply_to_footer(footer, false))
            assert.is_false(footer.settings.wifi_status)
            assert.equals(1, footer.mode)
            assert.equals(2, #footer.calls)
            assert.equals("set_has_no_mode", footer.calls[1])
            assert.equals("reschedule", footer.calls[2])
        end)
    end)

    describe("compute_mode_positions (v5.7.1 fix)", function()
        it("drops device-gated items: frontlight-less K4 puts wifi_status at 10", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            local pos = FI.compute_mode_positions({})
            assert.equals(0, pos.off)
            assert.equals(1, pos.page_progress)
            assert.equals(5, pos.battery)
            assert.equals(9, pos.mem_usage)
            assert.equals(10, pos.wifi_status)
            assert.equals(11, pos.book_title)
            assert.is_nil(pos.frontlight)
            assert.is_nil(pos.frontlight_warmth)
        end)

        it("keeps MODE order (wifi at 11) on a frontlight-equipped device", function()
            stub_device({ wifi = true, battery = true, frontlight = true, natural_light = true })
            local pos = FI.compute_mode_positions({})
            assert.equals(9, pos.frontlight)
            assert.equals(10, pos.mem_usage)
            assert.equals(11, pos.wifi_status)
        end)

        it("mirrors a saved custom order, then completes with the rest", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            local pos = FI.compute_mode_positions({
                order = { [0] = "off", [1] = "wifi_status", [2] = "page_progress", [3] = "battery" },
            })
            assert.equals(0, pos.off)
            assert.equals(1, pos.wifi_status)
            assert.equals(2, pos.page_progress)
            assert.equals(3, pos.battery)
            -- completion fills the remaining ungated items in MODE order
            assert.equals(4, pos.pages_left_book)
            assert.equals(5, pos.time)
            assert.equals(10, pos.mem_usage)
        end)

        it("skips gated items listed in a custom order", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            local pos = FI.compute_mode_positions({
                order = { [0] = "off", [1] = "wifi_status", [2] = "frontlight", [3] = "page_progress" },
            })
            assert.equals(1, pos.wifi_status)
            -- frontlight is device-gated away; page_progress takes slot 2
            assert.equals(2, pos.page_progress)
            assert.is_nil(pos.frontlight)
        end)

        it("appends an unknown mode from a custom order (audit item 3 fallback)", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            local pos = FI.compute_mode_positions({
                order = { [0] = "off", [1] = "wifi_status", [2] = "some_future_mode" },
            })
            -- an unrecognised mode is not dropped; it takes the next slot,
            -- ungated, so the persisted reader_footer_mode stays self-consistent
            assert.equals(1, pos.wifi_status)
            assert.equals(2, pos["some_future_mode"])
        end)

        it("falls back to the K4 shape when no device module exists", function()
            -- explicitly drop the default stub from before_each: the module
            -- must be ABSENT for this fallback path
            package.preload["device"] = nil
            package.loaded["device"] = nil
            -- no package.preload["device"]: pcall(require) fails, the
            -- frontlight family is assumed absent
            local pos = FI.compute_mode_positions({})
            assert.equals(10, pos.wifi_status)
        end)

        it("treats a device probe error as unavailable capability", function()
            package.preload["device"] = function()
                return {
                    hasFastWifiStatusQuery = function()
                        error("hal9000")
                    end,
                }
            end
            package.loaded["device"] = nil
            local pos = FI.compute_mode_positions({})
            assert.is_nil(pos.wifi_status)
        end)
    end)

    describe("apply_to_store (no live footer)", function()
        it("snapshots the pre-state and collapses to coexist items", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            local fs = { wifi_status = false, all_at_once = false, page_progress = true }
            store.data.footer = fs
            assert.is_true(FI.apply_to_store(store, true))
            assert.equals(fs, store.data.footer)
            assert.is_true(fs.wifi_status)
            -- Plan A coexist: all_at_once flips ON and the bar collapses to
            -- page progress + icon (the v5.7 no-flip rule is superseded)
            assert.is_true(fs.all_at_once)
            -- the pre-A table rides out in the backup key
            local backup = store.data.footer_pre_wifiicon_backup
            assert.is_table(backup)
            assert.is_false(backup.all_at_once)
            -- single-mode contract: the persisted mode is the COMPUTED wifi
            -- position (10 on a frontlight-less K4), not the MODE value 11
            assert.equals(10, store.data.reader_footer_mode)
            assert.equals(1, store.flushed)
        end)

        it("seeds a complete table from KOReader defaults and backs it up", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            assert.is_true(FI.apply_to_store(store, true))
            local fs = store.data.footer
            assert.is_table(fs)
            assert.is_true(fs.wifi_status)
            assert.is_true(fs.all_at_once)
            -- collapse evidence: default-on items are forced off, non-boolean
            -- keys survive untouched
            assert.is_false(fs.time)
            assert.equals("icons", fs.item_prefix)
            -- the seeded defaults were persisted BEFORE the collapse, so the
            -- backup holds them verbatim (restore guarantee for fresh users)
            local backup = store.data.footer_pre_wifiicon_backup
            assert.is_table(backup)
            assert.is_false(backup.all_at_once)
            assert.is_true(backup.time)
            assert.equals(10, store.data.reader_footer_mode)
            assert.equals(1, store.flushed)
        end)

        it("round-trips a seeded store: disable restores the KOReader defaults", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            assert.is_true(FI.apply_to_store(store, true))
            assert.is_true(store.data.footer.all_at_once)
            assert.is_true(FI.apply_to_store(store, false))
            local fs = store.data.footer
            assert.is_false(fs.wifi_status)
            -- defaults came back, not the collapsed set
            assert.is_false(fs.all_at_once)
            assert.is_true(fs.time)
            assert.equals(true, fs.page_progress)
            assert.is_nil(store.data.footer_pre_wifiicon_backup)
        end)

        it("persists the custom-order wifi position when an order exists", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            store.data.footer = {
                wifi_status = false,
                page_progress = true,
                order = { [0] = "off", [1] = "wifi_status", [2] = "page_progress", [3] = "battery" },
            }
            assert.is_true(FI.apply_to_store(store, true))
            assert.equals(1, store.data.reader_footer_mode)
        end)

        it("restores the persisted mode on disable only when it points at wifi", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            assert.is_true(FI.apply_to_store(store, true))
            assert.equals(10, store.data.reader_footer_mode)
            assert.is_true(FI.apply_to_store(store, false))
            assert.is_false(store.data.footer.wifi_status)
            assert.equals(1, store.data.reader_footer_mode)
            -- a mode the user set himself (not the one we wrote) is not
            -- clobbered by a disable that finds wifi already off
            store.data.reader_footer_mode = 3
            assert.is_true(FI.apply_to_store(store, false))
            assert.equals(3, store.data.reader_footer_mode)
        end)

        it("returns false instead of writing a partial table when defaults are gone", function()
            stub_device({ wifi = true, battery = true, frontlight = false })
            package.loaded["apps/reader/modules/readerfooter"] = nil
            package.preload["apps/reader/modules/readerfooter"] = function()
                return nil
            end
            local ok = FI.apply_to_store(store, true)
            package.preload["apps/reader/modules/readerfooter"] = function()
                return {
                    default_settings = {
                        disable_progress_bar = false,
                        all_at_once = false,
                        page_progress = true,
                        time = true,
                        pages_left = true,
                        percentage = true,
                        battery = true,
                        wifi_status = false,
                        item_prefix = "icons",
                    },
                }
            end
            package.loaded["apps/reader/modules/readerfooter"] = nil
            assert.is_false(ok)
            assert.is_nil(store.data.footer)
        end)

        it("rejects a missing or malformed store", function()
            assert.is_false(FI.apply_to_store(nil, true))
            assert.is_false(FI.apply_to_store({}, true))
        end)
    end)

    describe("flush safety", function()
        it("swallows store flush errors", function()
            store.flush = function()
                error("disk on fire")
            end
            local footer = make_footer()
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_true(FI.apply_to_store(store, true))
        end)

        it("tolerates a store without flush", function()
            local bare = {
                data = {},
                readSetting = function(self, key, default)
                    local value = self.data[key]
                    if value == nil then return default end
                    return value
                end,
                saveSetting = function(self, key, value)
                    self.data[key] = value
                end,
            }
            assert.is_true(FI.apply_to_store(bare, true))
        end)
    end)
end)