#!/usr/bin/env python3
"""Verify vendored files against the pinned official-source hashes; no network."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
total = 0
lock = json.loads((root / "vendor-lock.json").read_text())
for component in lock["components"]:
    for name, expected in component["files"].items():
        target = root / name
        if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != expected:
            raise SystemExit(f"Upstream file differs: {target}")
        total += 1
print(f"Verified {total} upstream files; no modifications.")
