#!/usr/bin/env python3
"""P0-a (2026-10-26 unified review v2): version single-source gate.

Batch bumps used to touch only _meta.lua, so main.lua's About-dialog version
drifted (device advertised v7.6 while actually running v8.1 — the exact
mismatch the welite report's finding #1 and the v2 report's §3.2 pinned
down). This gate fails on any drift between the two literals. stdlib-only,
same shape as check_module_map.py.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Both files declare the key as its own line (`version = "..."` inside a
# table constructor). Anchor on the line to avoid matching diagnostics like
# logger.info("version=", self.version) in main.lua.
VERSION_PATTERN = re.compile(r'^\s*version\s*=\s*"([^"]+)"', re.MULTILINE)


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
    meta_version = read_version(ROOT / "_meta.lua", "_meta.lua")
    main_version = read_version(ROOT / "main.lua", "main.lua")
    if meta_version is None or main_version is None:
        return 1
    if meta_version != main_version:
        print(
            "[FAIL] version drift: main.lua "
            f"{main_version!r} != _meta.lua {meta_version!r} "
            "(P0-a: bump both in the same change)"
        )
        return 1
    print(f"version sync OK: {main_version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
