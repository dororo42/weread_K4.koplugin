-- Unit tests for weread/ui/login_hint.lua (P1-C §六·3, 2026-09-18): the
-- persistent "login expired" footer hint built on the native custom_text
-- footer item. ReaderFooter is an in-memory double; G_reader_settings is a
-- stubbed LuaSettings-shaped store. Focus: inject/restore round-trip,
-- snapshot-before-mutate (power-loss safety), idempotent re-show, the
-- single-mode refusal (K4 non-touch footer must not lose page progress),
-- and nil-safety outside a live ReaderUI.
local LH = require("weread.ui.login_hint")

describe("login_hint", function()
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

    local function make_footer(opts)
        opts = opts or {}
        local repaints = 0
        local footer = {
            settings = opts.settings
                or { all_at_once = true, custom_text = false, page_progress = true },
            custom_text = opts.custom_text or "KOReader",
            custom_text_repetitions = opts.repetitions or 1,
            -- resolve_footer() probes for this method.
            set_has_no_mode = function() end,
        }
        function footer:updateFooterTextGenerator()
            repaints = repaints + 1
            return true
        end
        function footer:refreshFooter() repaints = repaints + 1 end
        footer.repaint_count = function() return repaints end
        return footer
    end

    local function make_ui(footer)
        return { view = { footer = footer } }
    end

    describe("show", function()
        it("injects the hint into an all_at_once footer", function()
            local footer = make_footer()
            local ok, reason = LH.show(make_ui(footer), "WR 登录过期")
            assert.is_true(ok)
            assert.is_nil(reason)
            assert.equals("WR 登录过期", footer.custom_text)
            assert.equals(1, footer.custom_text_repetitions)
            assert.is_true(footer.settings.custom_text)
            assert.equals("WR 登录过期", store.data.reader_footer_custom_text)
            assert.equals(1, store.data.reader_footer_custom_text_repetitions)
            assert.is_true(footer.repaint_count() > 0)
            assert.is_true(store.flushed > 0)
        end)

        it("snapshots the pre-state before the first mutation", function()
            local footer = make_footer({
                settings = { all_at_once = true, custom_text = true, page_progress = true },
                custom_text = "MYTEXT",
                repetitions = 3,
            })
            store.data.reader_footer_custom_text = "MYTEXT"
            store.data.reader_footer_custom_text_repetitions = 3
            LH.show(make_ui(footer), "HINT")
            local backup = store.data.footer_weread_login_hint_backup
            assert.is_true(type(backup) == "table")
            assert.is_true(backup.enabled)
            assert.equals("MYTEXT", backup.text)
            assert.equals(3, backup.repetitions)
            assert.equals("MYTEXT", backup.g_text)
            assert.equals(3, backup.g_repetitions)
        end)

        it("is idempotent: a repeated show refreshes the text, not the snapshot", function()
            local footer = make_footer({ custom_text = "KEEPME" })
            LH.show(make_ui(footer), "HINT1")
            LH.show(make_ui(footer), "HINT2")
            assert.equals("HINT2", footer.custom_text)
            local backup = store.data.footer_weread_login_hint_backup
            assert.equals("KEEPME", backup.text)
        end)

        it("refuses a single-mode footer (K4 non-touch safety)", function()
            local footer = make_footer({
                settings = { all_at_once = false, custom_text = false, page_progress = true },
            })
            local ok, reason = LH.show(make_ui(footer), "HINT")
            assert.is_false(ok)
            assert.equals("single_mode", reason)
            assert.is_false(footer.settings.custom_text)
            assert.equals("KOReader", footer.custom_text)
            assert.is_nil(store.data.footer_weread_login_hint_backup)
        end)

        it("is nil-safe without a live footer", function()
            assert.is_false(LH.show(nil, "HINT"))
            assert.is_false(LH.show({}, "HINT"))
            assert.is_false(LH.show({ view = {} }, "HINT"))
            assert.is_nil(store.data.footer_weread_login_hint_backup)
        end)

        it("falls back to a placeholder when text is not a usable string", function()
            local footer = make_footer()
            LH.show(make_ui(footer), nil)
            assert.equals("WeRead", footer.custom_text)
        end)
    end)

    describe("hide", function()
        it("restores the pre-episode state verbatim", function()
            local footer = make_footer({
                settings = { all_at_once = true, custom_text = true, page_progress = true },
                custom_text = "MYTEXT",
                repetitions = 3,
            })
            store.data.reader_footer_custom_text = "MYTEXT"
            store.data.reader_footer_custom_text_repetitions = 3
            LH.show(make_ui(footer), "HINT")
            local ok = LH.hide(make_ui(footer))
            assert.is_true(ok)
            assert.is_true(footer.settings.custom_text)
            assert.equals("MYTEXT", footer.custom_text)
            assert.equals(3, footer.custom_text_repetitions)
            assert.equals("MYTEXT", store.data.reader_footer_custom_text)
            assert.equals(3, store.data.reader_footer_custom_text_repetitions)
            assert.is_nil(store.data.footer_weread_login_hint_backup)
        end)

        it("deletes persisted G keys the user never set", function()
            local footer = make_footer()
            LH.show(make_ui(footer), "HINT")
            LH.hide(make_ui(footer))
            assert.is_nil(store.data.reader_footer_custom_text)
            assert.is_nil(store.data.reader_footer_custom_text_repetitions)
            -- The item the user never enabled goes back off.
            assert.is_false(footer.settings.custom_text)
            assert.equals("KOReader", footer.custom_text)
        end)

        it("is a no-op without a snapshot", function()
            assert.is_false(LH.hide(make_ui()))
            assert.is_false(LH.hide(nil))
        end)

        it("clears the snapshot even when no live footer exists", function()
            local footer = make_footer()
            LH.show(make_ui(footer), "HINT")
            -- ReaderUI closed; hide runs from a fresh context (no footer).
            assert.is_true(LH.hide(nil))
            assert.is_nil(store.data.footer_weread_login_hint_backup)
            assert.equals("HINT", store.data.reader_footer_custom_text)
        end)
    end)

    describe("is_active", function()
        it("tracks the snapshot lifecycle", function()
            assert.is_false(LH.is_active())
            local footer = make_footer()
            LH.show(make_ui(footer), "HINT")
            assert.is_true(LH.is_active())
            LH.hide(make_ui(footer))
            assert.is_false(LH.is_active())
        end)
    end)
end)
