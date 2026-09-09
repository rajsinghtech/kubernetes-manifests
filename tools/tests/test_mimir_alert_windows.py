#!/usr/bin/env python3
"""Offline proof for the short counter-window static lint."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools/check-mimir-alert-windows.py"


def run_scan(rule_dir: Path, max_window: str = "5m") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(TOOL),
            "--rules-dir",
            str(rule_dir),
            "--max-window",
            max_window,
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="mimir-alert-windows-") as temporary:
        root = Path(temporary)
        (root / "rules.yaml").write_text(
            """groups:
  - name: test.rules
    rules:
      - alert: ShortCounterWindow
        expr: increase(test_events_total[5m]) > 0
        for: 0m
      - alert: HeldCounterWindow
        expr: increase(test_events_total[5m]) > 0
        for: 1m
      - alert: LongerZeroForWindow
        expr: rate(test_events_total[10m]) > 0
        for: 0m
"""
        )

        result = run_scan(root)
        assert result.returncode == 1, result
        assert "ShortCounterWindow" in result.stdout, result.stdout
        assert "findings=1" in result.stdout, result.stdout
        assert "LongerZeroForWindow" not in result.stdout, result.stdout

        broader = run_scan(root, "10m")
        assert broader.returncode == 1, broader
        assert "ShortCounterWindow" in broader.stdout, broader.stdout
        assert "LongerZeroForWindow" in broader.stdout, broader.stdout
        assert "findings=2" in broader.stdout, broader.stdout

    print("✓ Mimir alert-window lint: short zero-for counter window detected")
    print("✓ Mimir alert-window lint: held and longer windows are threshold-aware")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
