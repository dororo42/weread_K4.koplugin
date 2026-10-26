#!/usr/bin/env bash
# Build the device release package (v8.1 re-release fix, 2026-10-20).
#
# The package MUST contain a top-level `weread_K4.koplugin/` directory:
# KOReader discovers plugins as <plugins>/<name>.koplugin/_meta.lua. The
# v8.1 first release shipped a FLAT zip (main.lua at the archive root), so
# extracting it scattered the files and the plugin vanished from the menu
# entirely. --prefix enforces the wrapper; keep it, always.
#
# Runtime manifest (device loads nothing else): main.lua, _meta.lua,
# reader_menu_order.lua, docs, weread/, tools/clear_stale_backlog.lua.
# Dev assets (spec/, dev/, module-map.json, tools/*.py, .github/, ...) and
# local-only files (handoffs/, .workbuddy/, *.zip) never enter the package.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

version=$(grep -o 'version = "[^"]*"' _meta.lua | cut -d'"' -f2)
suffix=${version##*-}            # "0.6.0-k4-v8.1" -> "v8.1"
out="weread_K4.koplugin-${suffix}.zip"

git archive --format=zip --prefix="weread_K4.koplugin/" -o "$out" HEAD -- \
    main.lua _meta.lua reader_menu_order.lua README.md LICENSE NOTICE \
    weread tools/clear_stale_backlog.lua

# P0-b (2026-10-26 unified review v2): every release package ships with its
# sha256 digest next to it. The v8.1 first release was a hand-made flat zip
# built outside this script (files scattered, plugin vanished) — checksums
# only make sense together with the rule: ALWAYS build via this script, never
# by hand. Release notes must quote the digest line below.
# P0-A (2026-10-26 unified review v3): refuse to package a dirty tree — the
# v8.1 release shipped an uncommitted main.lua (version field diverged from
# every git commit, log line numbers untraceable).
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "REFUSING to build: worktree is dirty (uncommitted changes would ship untraceable code)" >&2
    git status --porcelain >&2
    exit 1
fi
sha256sum "$out" | tee "${out}.sha256"

echo "built ${out} (from $(git rev-parse --short HEAD), _meta version ${version})"
unzip -l "$out" | tail -3
