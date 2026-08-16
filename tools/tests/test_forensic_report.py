"""Focused path-compatibility tests for tools/forensic-report.py."""

import importlib.util
import sys
from pathlib import Path


ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
SOURCE = ROOT / "tools" / "forensic-report.py"
SPEC = importlib.util.spec_from_file_location("rftd_forensic_report", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


cases = {
    Path("RFTD/forensic/guardian/2026-08-16/2026-08-16_12-00-00Z_1_000.guardian.jsonl.log"): "guardian",
    Path("RFTD/forensic/tripwire/000.tripwire.jsonl.log"): "tripwire",
    Path("copied/2026-08-16_12-00-00Z_1_003.lifecycle.jsonl.log"): "lifecycle",
    Path("guardian/000.jsonl.log"): "guardian",
    Path("guardian/000.jsonl"): "guardian",
}

for path, expected in cases.items():
    actual = MODULE.stream_of(path)
    if actual != expected:
        raise AssertionError(f"{path}: got stream {actual!r}, want {expected!r}")

print(f"test_forensic_report: {len(cases)} passed, 0 failed")
