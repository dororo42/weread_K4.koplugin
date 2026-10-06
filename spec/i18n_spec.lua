-- B7 (upstream 6a577ad borrow): i18n language fallback — when no explicit
-- "language" setting exists, follow KOReader's initialized gettext locale
-- before defaulting to English.
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end

-- busted single state: earlier specs (settings_spec) leave an i18n stub in
-- package.preload/loaded; load the REAL module for these tests and restore
-- the pre-spec state at teardown.
local __PRE_I18N = { loaded = package.loaded["weread.lib.i18n"], preload = package.preload["weread.lib.i18n"] }
package.loaded["weread.lib.i18n"] = nil
package.preload["weread.lib.i18n"] = nil
local I18n = require("weread.lib.i18n")
teardown(function()
    if __PRE_I18N.loaded ~= nil then
        package.loaded["weread.lib.i18n"] = __PRE_I18N.loaded
    else
        package.loaded["weread.lib.i18n"] = nil
    end
    if __PRE_I18N.preload ~= nil then
        package.preload["weread.lib.i18n"] = __PRE_I18N.preload
    else
        package.preload["weread.lib.i18n"] = nil
    end
end)

describe("I18n.language fallback chain (B7)", function()
    local saved_gettext
    local saved_settings

    before_each(function()
        saved_gettext = package.loaded["gettext"]
        saved_settings = _G.G_reader_settings
    end)
    after_each(function()
        package.loaded["gettext"] = saved_gettext
        _G.G_reader_settings = saved_settings
    end)

    it("prefers the explicit language setting", function()
        _G.G_reader_settings = { readSetting = function() return "fr" end }
        assert.equals("fr", I18n.language())
    end)

    it("falls back to the KOReader gettext locale when no setting exists", function()
        _G.G_reader_settings = { readSetting = function() return nil end }
        package.loaded["gettext"] = { current_lang = "zh" }
        assert.equals("zh", I18n.language())
    end)

    it("defaults to en without a setting and without gettext", function()
        _G.G_reader_settings = { readSetting = function() return nil end }
        package.loaded["gettext"] = nil
        assert.equals("en", I18n.language())
    end)
end)
