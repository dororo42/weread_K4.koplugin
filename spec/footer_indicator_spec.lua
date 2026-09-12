-- Unit tests for weread/ui/footer_indicator.lua: the glue that toggles
-- KOReader's built-in ReaderFooter "wifi_status" item from the WeRead menu.
-- KOReader's ReaderFooter is replaced by an in-memory double that records
-- the call sequence, and G_reader_settings / readerfooter.default_settings
-- are stubbed. Focus: state mutation, the refresh bookkeeping contract
-- (mirror of readerfooter.lua's own toggle callback), and the FileManager
-- (no-live-footer) store path.
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
    end)

    after_each(function()
        _G.G_reader_settings = nil
    end)

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
        footer.set_has_no_mode = function(self)
            table.insert(self.calls, "set_has_no_mode")
            for _, key in ipairs(
                { "page_progress", "time", "pages_left", "percentage", "battery", "wifi_status" }) do
                if self.settings[key] == true then
                    self.has_no_mode = false
                    return 1
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
        footer.applyFooterMode = function(self)
            table.insert(self.calls, "applyFooterMode")
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

        it("enables and refreshes in all_at_once mode", function()
            local footer = make_footer()
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_true(footer.settings.wifi_status)
            assert.equals("set_has_no_mode", footer.calls[1])
            assert.is_true(#footer.calls >= 4)
            assert.equals("updateFooterTextGenerator", footer.calls[2])
            assert.equals("refreshFooter:true:false", footer.calls[3])
            assert.equals("reschedule", footer.calls[#footer.calls])
        end)

        it("enables from a no-mode footer and restores a mode (signal path)", function()
            local footer = make_footer({
                settings = { wifi_status = false, all_at_once = true },
                has_no_mode = true,
                mode = 0,
            })
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_false(footer.has_no_mode)
            assert.equals(1, footer.mode)
            assert.is_true(footer.settings.wifi_status)
            -- native order: set_has_no_mode, applyFooterMode + persist,
            -- updateFooterTextGenerator, refreshFooter(true, true), reschedule
            assert.equals("applyFooterMode", footer.calls[2])
            assert.equals("updateFooterTextGenerator", footer.calls[3])
            assert.equals("refreshFooter:true:true", footer.calls[4])
            assert.equals("reschedule", footer.calls[5])
            assert.equals(1, store.data.reader_footer_mode)
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

        it("does not repaint when a single-mode item quietly joins the cycle", function()
            local footer = make_footer({
                settings = { wifi_status = false, all_at_once = false, page_progress = true },
                mode = 1,
            })
            assert.is_true(FI.apply_to_footer(footer, true))
            assert.is_true(footer.settings.wifi_status)
            assert.equals(1, footer.mode)
            -- native behavior: bookkeeping + auto-refresh reschedule only,
            -- the item becomes visible after the user cycles the mode
            assert.equals(2, #footer.calls)
            assert.equals("set_has_no_mode", footer.calls[1])
            assert.equals("reschedule", footer.calls[2])
        end)
    end)

    describe("apply_to_store (no live footer)", function()
        it("mutates an existing footer table in place", function()
            local fs = { wifi_status = false, all_at_once = false, page_progress = true }
            store.data.footer = fs
            assert.is_true(FI.apply_to_store(store, true))
            assert.equals(fs, store.data.footer)
            assert.is_true(fs.wifi_status)
            assert.is_true(fs.all_at_once)
            assert.equals(1, store.flushed)
        end)

        it("seeds a complete table from KOReader defaults when missing", function()
            assert.is_true(FI.apply_to_store(store, true))
            local fs = store.data.footer
            assert.is_table(fs)
            assert.is_true(fs.wifi_status)
            assert.is_true(fs.all_at_once)
            -- completeness: non-target keys must survive, not be nil'ed
            assert.equals(true, fs.page_progress)
            assert.equals("icons", fs.item_prefix)
            assert.equals(1, store.flushed)
        end)

        it("seeding on disable leaves all_at_once untouched", function()
            assert.is_true(FI.apply_to_store(store, true))
            local fs = store.data.footer
            fs.all_at_once = false
            assert.is_true(FI.apply_to_store(store, false))
            assert.is_false(fs.wifi_status)
            assert.is_false(fs.all_at_once)
        end)

        it("returns false instead of writing a partial table when defaults are gone", function()
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
