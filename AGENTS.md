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
  (CI verifies it is an ancestor of HEAD, F-07), and bump the `README.md`
  version literals in the same change — `tools/check_version_sync.py` now
  checks README too (2026-11-12 audit, I-2).
- Rename the `## [Unreleased]` section of `ChangeLog.md` to
  `## [<tag>] - YYYY-MM-DD` BEFORE pushing the tag: `release.yml` derives
  release notes from that exact heading and fails when it is missing (F-8).
- Update `ChangeLog.md` with the batch summary (README links to it); commit
  message follows: `<version>批次: <变更摘要>，详见ChangeLog.md`.
- Full gate before commit: busted + luacheck + luac -p + module-map + version-sync + clean tree.

## Where things live

- `weread/lib/` — logic: protocol (URL/sign), client (HTTP), content (chapters),
  downloader, progress_sync, settings, credential_store, stats…
- `weread/ui/` — KOReader widgets (presentation; most are documented exceptions
  in module-map.json).
- `spec/` — busted specs; stub patterns per file header comments.
- `tools/` — CI gate scripts.

## Current Handoff

- Latest: `handoffs/2026-11-12-134405-weread-k4-three-repo-audit-fix/HANDOFF.md`
- Branch: main @ 83917f0
- Status: **三仓审查复核意见落地（2026-11-12）**：版本门禁扩展到 README、`client.lua` 注释对齐、`ChangeLog.md` 预置 `[Unreleased]`（含 R4/k4tls 顺延条）；本仓为 Lua 生产源，镜像已同步到 Rust 仓。21 项逐条确认见 HANDOFF.md「三仓协同」§4。版本未递增、v9.13 仍暂缓发包；修复**未 commit / push**（待授权），未构建、未连真机。

任何 agent 开始工作前，先读上面的 HANDOFF.md。这份指针由 orbital_handoff 维护，手工交接时请同步更新。
