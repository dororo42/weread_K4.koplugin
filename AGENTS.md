# AGENTS.md — Guide for AI Coding Agents

weread_K4.koplugin: a KOReader plugin for WeRead (微信读书) on Kobo/Kindle e-readers.
Lua 5.1 + LuaJIT ffi, runs on device; specs run on plain Lua 5.1 under busted.

## Non-negotiable rules

1. **Tests travel with fixes.** Every behavior change ships with/updates a spec in
   the same change. CI fails on a dirty worktree (F-22) — never leave fixes
   uncommitted.
2. **Module-map upkeep (N-2).** Adding/removing/renaming a module under
   `weread/` (or `main.lua`, `reader_menu_order.lua`) requires updating
   `module-map.json` in the same change. Every module needs at least one spec,
   or an explicit `"reason"` documenting the exception. Gate:
   `python3 tools/check_module_map.py` (also a CI step). Adding a spec file
   requires referencing it from the covered module's entry (orphan specs fail).
3. **Strict Lua 5.1.** No post-5.1 syntax (`\x`/`\z` escapes, `goto`, `//`).
   CI parses every tracked file with `luac -p` and runs specs on standard 5.1.
4. **Never break the spec runtime.** Specs run without ffi/KOReader/device.
   Stub device modules via the `preload + package.loaded` pattern (see
   `spec/client_redirect_spec.lua` / `spec/path_guard_spec.lua`). Beware:
   busted loads every spec file's top-level code before running any test —
   do not require device modules at spec top level; install stubs lazily in
   the run phase and *clear* (not snapshot-restore) them at teardown
   (see `spec/protocol_spec.lua` for the reasoning).
5. **Credentials & secrets.** Credentials live only in
   `weread/lib/credential_store.lua` (0600 file, `weread-credentials-v1`
   format). Never log them; sanitize before any persistence (N-3).
6. **Network safety.** All downloads go through `weread/lib/client.lua`:
   size caps (`MAX_BINARY_BYTES`), redirect validation, bounded sinks (N-1).
   Do not bypass it with raw `socket.http` calls.

## Commands

```sh
~/.luarocks/bin/busted spec          # unit tests (295+ specs)
~/.luarocks/bin/luacheck weread spec tools main.lua _meta.lua
luac -p $(git ls-files '*.lua')      # strict 5.1 syntax sentinel
python3 tools/check_module_map.py    # module-map gate
```

## Release discipline

- Bump version in `_meta.lua`, refresh `build_commit` in `main.lua`
  (CI verifies it is an ancestor of HEAD, F-07).
- Update `README.md` changelog with the batch summary; commit message
  follows: `<version>批次: <变更摘要>，详见README.md`.
- Full gate before commit: busted + luacheck + luac -p + module-map + clean tree.

## Where things live

- `weread/lib/` — logic: protocol (URL/sign), client (HTTP), content (chapters),
  downloader, progress_sync, settings, credential_store, stats…
- `weread/ui/` — KOReader widgets (presentation; most are documented exceptions
  in module-map.json).
- `spec/` — busted specs; stub patterns per file header comments.
- `tools/` — CI gate scripts.
