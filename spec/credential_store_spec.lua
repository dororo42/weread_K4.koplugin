-- Unit tests for weread/lib/credential_store.lua (N-3, 2026-10-20 audit):
-- the dedicated 0600 credential file that replaced plaintext credentials in
-- weread.lua (LuaSettings, typically 0644 — world-readable whenever the
-- Kindle is USB-mounted).
--
-- Runs against a real temp directory. Under Lua 5.1 (busted/CI) the module's
-- io.open + chmod fallback is the path under test; the ffi path is
-- device-only (LuaJIT) and shares the same write/fsync/rename sequence.
local CredentialStore = require("weread.lib.credential_store")

local TEST_DIR = "/tmp/weread-credential-store-test"
local TEST_PATH = TEST_DIR .. "/weread.credentials.lua"

local function reset()
    os.execute("rm -rf " .. TEST_DIR)
    os.execute("mkdir -p " .. TEST_DIR)
end

local function file_mode(path)
    local handle = io.popen(string.format("stat -c %%a %q", path))
    if not handle then
        return nil
    end
    local mode = handle:read("*a")
    handle:close()
    return mode and mode:gsub("%s+$", "") or nil
end

describe("CredentialStore round-trip", function()
    before_each(reset)

    it("writes and reads back a full credential payload", function()
        local store = assert(CredentialStore.new(TEST_PATH))
        local ok, err = store:save({
            api_key = "wrk-abc123",
            wr_ticket = "",
            wr_wrpa = "",
            cookies = { wr_skey = "skey-xyz", wr_vid = "12345" },
            account = { name = "tester", user_vid = "12345", login_time = 1700000000 },
        })
        assert.is_true(ok)
        assert.is_nil(err)
        assert.is_true(store:exists())
        local loaded = store:load()
        assert.equals("wrk-abc123", loaded.api_key)
        assert.equals("skey-xyz", loaded.cookies.wr_skey)
        assert.equals("12345", loaded.cookies.wr_vid)
        assert.equals("tester", loaded.account.name)
        assert.equals(1700000000, loaded.account.login_time)
    end)

    it("escapes control characters and percent signs in values", function()
        local store = assert(CredentialStore.new(TEST_PATH))
        -- Account fields are display-only and may legitimately arrive with
        -- odd characters; cookie values stay injection-safe (sanitize still
        -- rejects CR/LF/';' in them — the escaping is about file safety,
        -- not a licence to store header-unsafe cookies).
        assert.is_true(store:save({
            cookies = { wr_skey = "abc%def" },
            account = { name = "a\tb\nc%d" },
        }))
        local loaded = store:load()
        assert.equals("abc%def", loaded.cookies.wr_skey)
        assert.equals("a\tb\nc%d", loaded.account.name)
    end)

    it("creates the file with 0600 permissions", function()
        local store = assert(CredentialStore.new(TEST_PATH))
        assert.is_true(store:save({ api_key = "wrk-1" }))
        assert.equals("600", file_mode(TEST_PATH))
    end)

    it("leaves no tmp behind and keeps the old payload when rename fails", function()
        local store = assert(CredentialStore.new(TEST_PATH))
        assert.is_true(store:save({ api_key = "first" }))
        -- F-11 lesson under test: os.rename signals failure by RETURNING
        -- (nil, msg); the save must check it, clean the tmp and keep the
        -- previous file intact.
        local saved_rename = os.rename
        -- luacheck: push
        -- luacheck: ignore os
        os.rename = function() return nil, "simulated failure" end
        local ok, err = store:save({ api_key = "second" })
        os.rename = saved_rename
        -- luacheck: pop
        -- Lua convention: nil + message on failure (truthy only on success)
        assert.is_nil(ok)
        assert.equals("rename failed", err)
        assert.is_nil(io.open(TEST_PATH .. ".tmp", "rb"))
        assert.equals("first", store:load().api_key)
    end)

    it("treats a missing file as empty rather than an error", function()
        local store = assert(CredentialStore.new(TEST_PATH))
        assert.is_false(store:exists())
        assert.same({}, store:load())
    end)

    it("ignores a malformed file instead of crashing", function()
        local store = assert(CredentialStore.new(TEST_PATH))
        local fh = assert(io.open(TEST_PATH, "wb"))
        fh:write("this is not the expected format\n")
        fh:close()
        assert.same({}, store:load())
    end)

    it("ignores a hand-edited payload that fails sanitisation", function()
        local store = assert(CredentialStore.new(TEST_PATH))
        local fh = assert(io.open(TEST_PATH, "wb"))
        fh:write("weread-credentials-v1\n")
        fh:write("cookie:tracker\tvalue\n")
        fh:write("cookie:wr_skey\ta\r\nb\n")
        fh:close()
        assert.same({}, store:load())
    end)
end)

describe("CredentialStore.sanitize", function()
    it("accepts a well-formed payload and normalises missing keys", function()
        local clean = assert(CredentialStore.sanitize({ api_key = "k" }))
        assert.equals("k", clean.api_key)
        assert.equals("", clean.wr_ticket)
        assert.same({}, clean.cookies)
        assert.same({}, clean.account)
    end)

    it("rejects implausible shapes", function()
        assert.is_nil(CredentialStore.sanitize("nope"))
        assert.is_nil(CredentialStore.sanitize({ api_key = 42 }))
        assert.is_nil(CredentialStore.sanitize({ api_key = "x\r\ny" }))
        assert.is_nil(CredentialStore.sanitize({ cookies = "x" }))
        assert.is_nil(CredentialStore.sanitize({ cookies = { wr_skey = "a;b" } }))
        assert.is_nil(CredentialStore.sanitize({ cookies = { tracker = "x" } }))
        assert.is_nil(CredentialStore.sanitize({ account = "x" }))
    end)

    it("enforces the per-value size cap", function()
        assert.is_nil(CredentialStore.sanitize({ api_key = string.rep("x", 8193) }))
    end)
end)
