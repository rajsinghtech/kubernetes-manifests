#!/usr/bin/env python3
"""Find alert rules whose short counter window can vanish before observation.

This is a static lint, not a replacement for the live label-contract check.
An increase()/rate()/irate() expression with for: 0m is only observable while
the range window contains the event.  When that window is no longer than a few
scrape intervals, a periodic sweep can miss a real event entirely.
"""

from __future__ import annotations

import argparse
import dataclasses
from pathlib import Path
import re
import sys
from typing import Iterable

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RULES_DIR = ROOT / "kubernetes/apps/base/mimir/mimir-ottawa/rules"
WINDOW_RE = re.compile(r"\[\s*([0-9]+(?:\.[0-9]+)?)\s*(ms|s|m|h|d)\s*\]")
FUNCTION_RE = re.compile(r"\b(increase|rate|irate)\s*\(")
ZERO_FOR_RE = re.compile(r"^\s*0(?:\.0+)?\s*(?:ms|s|m|h|d)?\s*$")
UNIT_SECONDS = {"ms": 0.001, "s": 1, "m": 60, "h": 3600, "d": 86400}


@dataclasses.dataclass(frozen=True)
class Finding:
    path: Path
    rule_name: str
    function: str
    window: str
    for_value: str

    @property
    def location(self) -> str:
        return f"{self.path.name}:alert={self.rule_name}"


def parse_duration(value: str) -> float:
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(ms|s|m|h|d)", value.strip())
    if not match:
        raise argparse.ArgumentTypeError(
            f"invalid duration {value!r}; use e.g. 5m, 30s, or 1h"
        )
    return float(match.group(1)) * UNIT_SECONDS[match.group(2)]


def rule_paths(rules_dir: Path) -> list[Path]:
    paths = sorted(rules_dir.glob("*.yaml")) + sorted(rules_dir.glob("*.yml"))
    if not paths:
        raise ValueError(f"no Mimir rule files found under {rules_dir}")
    return paths


def scan(paths: Iterable[Path], max_window: float) -> list[Finding]:
    findings: list[Finding] = []
    for path in paths:
        for document in yaml.safe_load_all(path.read_text()):
            if not isinstance(document, dict):
                continue
            for group in document.get("groups", []):
                if not isinstance(group, dict):
                    continue
                for rule in group.get("rules", []):
                    if not isinstance(rule, dict) or not isinstance(rule.get("alert"), str):
                        continue
                    expression = rule.get("expr")
                    if not isinstance(expression, str):
                        continue
                    for_value = str(rule.get("for", ""))
                    if not ZERO_FOR_RE.fullmatch(for_value):
                        continue
                    functions = sorted({match.group(1) for match in FUNCTION_RE.finditer(expression)})
                    if not functions:
                        continue
                    windows = [
                        (float(amount) * UNIT_SECONDS[unit], f"{amount}{unit}")
                        for amount, unit in WINDOW_RE.findall(expression)
                    ]
                    for function in functions:
                        for seconds, window in windows:
                            if seconds <= max_window:
                                findings.append(
                                    Finding(
                                        path=path,
                                        rule_name=rule["alert"],
                                        function=function,
                                        window=window,
                                        for_value=for_value,
                                    )
                                )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Find short rate/increase alert windows with for: 0m"
    )
    parser.add_argument(
        "--rules-dir",
        default=str(DEFAULT_RULES_DIR),
        help="directory containing native Mimir rule YAML files",
    )
    parser.add_argument(
        "--max-window",
        type=parse_duration,
        default=parse_duration("5m"),
        help="maximum range window to report (default: 5m)",
    )
    args = parser.parse_args()
    try:
        findings = scan(rule_paths(Path(args.rules_dir)), args.max_window)
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"Mimir alert-window scan failed: {error}", file=sys.stderr)
        return 2

    for finding in findings:
        print(
            f"✗ {finding.location}: {finding.function} [{finding.window}] "
            f"with for={finding.for_value}"
        )
    print(
        f"Mimir alert-window scan: findings={len(findings)} "
        f"max-window={args.max_window:g}s"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
