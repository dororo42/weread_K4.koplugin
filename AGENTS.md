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
~/.luarocks/bin/busted spec          # unit tests (309 specs as of v8.1)
~/.luarocks/bin/luacheck weread spec tools main.lua _meta.lua
luac -p $(git ls-files '*.lua')      # strict 5.1 syntax sentinel
python3 tools/check_module_map.py    # module-map gate
```

Note: `spec/mock_service_spec.lua` (B-3) additionally needs the `luasocket`
and `luajson` rocks and spawns `python3 dev/mock_gateway.py` locally.

## Release discipline

- Bump version in `_meta.lua`, refresh `build_commit` in `main.lua`
  (CI verifies it is an ancestor of HEAD, F-07).
- Update `ChangeLog.md` with the batch summary (README links to it); commit
  message follows: `<version>批次: <变更摘要>，详见ChangeLog.md`.
- Full gate before commit: busted + luacheck + luac -p + module-map + clean tree.

## Where things live

- `weread/lib/` — logic: protocol (URL/sign), client (HTTP), content (chapters),
  downloader, progress_sync, settings, credential_store, stats…
- `weread/ui/` — KOReader widgets (presentation; most are documented exceptions
  in module-map.json).
- `spec/` — busted specs; stub patterns per file header comments.
- `tools/` — CI gate scripts.

## Current Handoff

- Latest: `handoffs/2026-11-10-073303-weread-k4-login-recovery-fix/HANDOFF.md`
- Branch: main @ ac34e11
- Status: **v9.10 已推送并出包**（2026-11-10，tag `v9.10` @ `7b2582f`，release run `42821674362` success；资产 zip + sha256 齐备）。文档重构已入库：README changelog 拆分为中英双语 `ChangeLog.md`（标题链接引用）、`release.yml` 从该文件派生 notes、全部 **27 个 Release 说明双语统一**。busted 454/0、luacheck 0、四门禁全绿。剩余：真机 D10/D11 验收、K4（B00E）离线未部署、审查报告归档待用户拍板。

任何 agent 开始工作前，先读上面的 HANDOFF.md。这份指针由 orbital_handoff 维护，手工交接时请同步更新。
