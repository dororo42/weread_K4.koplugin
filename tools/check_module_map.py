#!/usr/bin/env python3
"""Module-map gate (N-2, 2026-10-20 audit).

Every runtime Lua module must appear in module-map.json with either:
  - at least one spec file exercising it, or
  - an explicit, non-empty "reason" documenting why it ships without a
    dedicated spec (device-only glue, trivial delegation, ...).

Fails (exit 1) on any drift:
  - runtime modules missing from the map
  - map entries pointing at modules that no longer exist (stale)
  - spec-less entries without a "reason" (or an empty one)
  - entries listing specs that do not exist (or malformed paths)
  - spec files not referenced by any module (orphans)

Stdlib only; run from anywhere: python3 tools/check_module_map.py
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAP_PATH = ROOT / "module-map.json"

# Runtime sources the gate enumerates. _meta.lua is excluded on purpose:
# declarative metadata (version/name), no runtime logic.
RUNTIME_SOURCES = [ROOT / "main.lua", ROOT / "reader_menu_order.lua"]
RUNTIME_TREES = [ROOT / "weread"]


def enumerate_modules():
    modules = {str(p.relative_to(ROOT)).replace("\\", "/") for p in RUNTIME_SOURCES if p.exists()}
    for tree in RUNTIME_TREES:
        modules |= {
            str(p.relative_to(ROOT)).replace("\\", "/")
            for p in tree.rglob("*.lua")
        }
    return modules


def enumerate_specs():
    spec_dir = ROOT / "spec"
    return {
        str(p.relative_to(ROOT)).replace("\\", "/")
        for p in spec_dir.glob("*_spec.lua")
    }


def main():
    errors = []

    if not MAP_PATH.exists():
        print(f"::error::module-map.json not found at {MAP_PATH}")
        return 1

    try:
        data = json.loads(MAP_PATH.read_text(encoding="utf-8"))
    except (ValueError, OSError) as exc:
        print(f"::error::module-map.json is not valid JSON: {exc}")
        return 1

    entries = data.get("modules")
    if not isinstance(entries, dict) or not entries:
        print("::error::module-map.json must contain a non-empty 'modules' object")
        return 1

    modules = enumerate_modules()
    specs = enumerate_specs()
    mapped_modules = set(entries)

    # 1) map <-> tree agreement
    for mod in sorted(modules - mapped_modules):
        errors.append(
            f"module not in module-map.json: {mod} — add an entry with its specs "
            f"or a documented 'reason' (see module-map.json _description)"
        )
    for mod in sorted(mapped_modules - modules):
        errors.append(f"stale module-map entry: {mod} does not exist in the tree")

    # 2) per-entry validation
    referenced_specs = set()
    for mod, entry in sorted(entries.items()):
        if not isinstance(entry, dict):
            errors.append(f"{mod}: entry must be an object with 'specs' and/or 'reason'")
            continue
        spec_list = entry.get("specs") or []
        reason = (entry.get("reason") or "").strip()
        if not isinstance(spec_list, list):
            errors.append(f"{mod}: 'specs' must be a list")
            continue
        if not spec_list and not reason:
            errors.append(
                f"{mod}: no specs and no 'reason' — every module needs a spec "
                f"or a documented exception"
            )
        for spec in spec_list:
            if not (isinstance(spec, str) and spec.startswith("spec/") and spec.endswith("_spec.lua")):
                errors.append(f"{mod}: malformed spec path {spec!r} (expected 'spec/*_spec.lua')")
                continue
            if spec not in specs:
                errors.append(f"{mod}: listed spec does not exist: {spec}")
            referenced_specs.add(spec)

    # 3) orphan spec detection (a spec that exercises no mapped module)
    for spec in sorted(specs - referenced_specs):
        errors.append(f"orphan spec (referenced by no module entry): {spec}")

    if errors:
        print(f"MODULE-MAP GATE: {len(errors)} problem(s)")
        for err in errors:
            print(f"::error::{err}")
        return 1

    covered = sum(1 for e in entries.values()
                  if isinstance(e, dict) and (e.get("specs") or []))
    print(
        f"MODULE-MAP GATE: OK — {len(modules)} modules mapped, "
        f"{covered} with direct specs, {len(entries) - covered} documented exceptions, "
        f"{len(specs)} spec files, 0 orphans"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
