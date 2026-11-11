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

# 2026-11-08 audit: git archive HEAD silently omits uncommitted fixes, and a
# version literal lagging behind HEAD ships unreleased code under an old
# version name. Refuse both — a release must be a clean, tagged commit.
# 2026-11-11: the CI-built libk4tls.so is fetched into the tree by
# release.yml right before packaging and stays untracked by design --
# exempt exactly that path from the clean-tree gate (any other dirt,
# including a modified .so, is still refused).
if [ -n "$(git status --porcelain | grep -v '^?? weread/lib/libk4tls.so$')" ]; then
    echo "error: working tree is not clean; commit fixes and specs together" >&2
    git status --porcelain | grep -v '^?? weread/lib/libk4tls.so$' >&2
    exit 1
fi
if ! git rev-parse -q --verify "refs/tags/${suffix}^{commit}" >/dev/null; then
    echo "error: no tag ${suffix} for version ${version}" >&2
    exit 1
fi
if [ "$(git rev-parse HEAD)" != "$(git rev-parse "refs/tags/${suffix}^{commit}")" ]; then
    echo "error: HEAD != tag ${suffix}; bump the version before packaging" >&2
    echo "  HEAD: $(git rev-parse --short HEAD)" >&2
    echo "  tag : $(git rev-parse --short "refs/tags/${suffix}^{commit}")" >&2
    exit 1
fi

git archive --format=zip --prefix="weread_K4.koplugin/" -o "$out" HEAD -- \
    main.lua _meta.lua reader_menu_order.lua README.md ChangeLog.md \
    LICENSE NOTICE weread tools/clear_stale_backlog.lua

# P0-b (2026-10-26 unified review v2): every release package ships with its
# sha256 digest next to it. The v8.1 first release was a hand-made flat zip
# built outside this script (files scattered, plugin vanished) — checksums
# only make sense together with the rule: ALWAYS build via this script, never
# by hand. Release notes must quote the digest line below.
# 2026-11-11: the CI-built TLS backend (libk4tls.so, fetched by
# release.yml from the K4WereadRust release asset) is untracked, so
# git archive above cannot include it -- append it at the correct
# in-package path when present. Local builds without the file keep
# the historical LuaSec-only package.
if [ -f "weread/lib/libk4tls.so" ]; then
    zip -q "$out" "weread_K4.koplugin/weread/lib/libk4tls.so"
fi

sha256sum "$out" | tee "${out}.sha256"

echo "built ${out} (from $(git rev-parse --short HEAD), _meta version ${version})"
unzip -l "$out" | tail -3
