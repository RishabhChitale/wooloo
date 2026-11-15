#!/usr/bin/env python3
"""Check that the sync conformance fixture matches the canonical copy in wooloo-win."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "..", "woolooTests", "Fixtures", "sync-vectors.json")
CANON = os.environ.get("WOOLOO_WIN_VECTORS", os.path.expanduser("~/Claude/wooloo-win/docs/sync-vectors.json"))

if not os.path.exists(CANON):
    print(f"skip: canonical vectors not found at {CANON}")
    sys.exit(0)
with open(FIXTURE, "rb") as a, open(CANON, "rb") as b:
    if a.read() != b.read():
        print("fixture differs from canonical: cp the wooloo-win file over woolooTests/Fixtures/sync-vectors.json")
        sys.exit(1)
print("sync-vectors.json matches")
