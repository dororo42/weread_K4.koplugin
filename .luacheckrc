-- Luacheck config for the weread_K4.koplugin K4 fork.
-- The plugin runs inside KOReader's LuaJIT VM (std "max" covers LuaJIT
-- builtins like `bit` plus the union of Lua std libs).
std = "max"
cache = true
max_line_length = 120
unused_args = false

-- KOReader globals the plugin legitimately reads.
globals = {
    "G_reader_settings",
}

-- busted suites.
files["spec"] = {
    std = "+busted",
}

-- Test-only global handles used to seed the LuaSettings/BookStore stubs.
files["spec/settings_spec.lua"] = {
    globals = {
        "__TEST_STORES",
        "__TEST_DISK",
    },
}
