#!/usr/bin/env python3
"""P0-a (2026-10-26 unified review v2): version single-source gate.

Batch bumps used to touch only _meta.lua, so main.lua's About-dialog version
drifted (device advertised v7.6 while actually running v8.1 — the exact
mismatch the welite report's finding #1 and the v2 report's §3.2 pinned
down). This gate fails on any drift between the two literals. stdlib-only,
same shape as check_module_map.py.

2026-11-12 three-repo audit (I-2 / F-9): README.md quoted v9.11 in three
places while _meta.lua and main.lua were v9.12, and the gate did not look at
README at all. Docs quoting the release version are now checked too.
"""

import argparse
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parent.parent

# Both files declare the key as its own line (`version = "..."` inside a
# table constructor). Anchor on the line to avoid matching diagnostics like
# logger.info("version=", self.version) in main.lua.
VERSION_PATTERN = re.compile(r'^\s*version\s*=\s*"([^"]+)"', re.MULTILINE)
# README quotes the version with an optional leading "v". Do not match the
# upstream baseline "v0.6.0" or "v1.4.0": only full 0.6.0-k4-v9.X strings.
DOC_VERSION_FILES = ("README.md",)
DOC_VERSION_PATTERN = re.compile(r"v?(0\.6\.0-k4-v9\.\d+)")


def read_version(path: Path, label: str):
    if not path.is_file():
        print(f"[FAIL] {label}: file not found at {path}")
        return None
    text = path.read_text(encoding="utf-8")
    matches = VERSION_PATTERN.findall(text)
    if not matches:
        print(f"[FAIL] {label}: no version literal found")
        return None
    if len(set(matches)) > 1:
        print(f"[FAIL] {label}: multiple differing version literals {matches}")
        return None
    return matches[0]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo-root", default=str(DEFAULT_ROOT),
                    help="repository root (defaults to the script's parent repo)")
    root = Path(ap.parse_args().repo_root)

    meta_version = read_version(root / "_meta.lua", "_meta.lua")
    main_version = read_version(root / "main.lua", "main.lua")
    if meta_version is None or main_version is None:
        return 1
    if meta_version != main_version:
        print(
            "[FAIL] version drift: main.lua "
            f"{main_version!r} != _meta.lua {meta_version!r} "
            "(P0-a: bump both in the same change)"
        )
        return 1

    for rel in DOC_VERSION_FILES:
        path = root / rel
        if not path.is_file():
            print(f"[FAIL] {rel}: file not found")
            return 1
        found = DOC_VERSION_PATTERN.findall(path.read_text(encoding="utf-8"))
        if not found:
            print(f"[FAIL] {rel}: no 0.6.0-k4-vX.Y version literal found")
            return 1
        drift = sorted({v for v in found if v != meta_version})
        if drift:
            print(f"[FAIL] {rel} version drift {drift} != {meta_version} "
                  "(update the docs together with _meta.lua / main.lua)")
            return 1

    print(f"version sync OK: {meta_version} "
          f"(_meta.lua, main.lua, {', '.join(DOC_VERSION_FILES)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
