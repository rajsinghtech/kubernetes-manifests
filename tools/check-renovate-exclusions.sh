#!/usr/bin/env bash
# check-renovate-exclusions.sh — keep disabled Renovate rules visible and dated.
#
# Every enabled:false package rule must be represented in the review ledger and
# carry a future Review-by date. This keeps a safe temporary hold from becoming
# an invisible permanent pin.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${RENOVATE_CONFIG_PATH:-$ROOT/.github/renovate.json}"
LEDGER="${RENOVATE_EXCLUSIONS_DOC:-$ROOT/docs/reference/renovate-exclusions.md}"
TODAY="${RENOVATE_EXCLUSIONS_TODAY:-$(date -u +%F)}"

python3 - "$CONFIG" "$LEDGER" "$TODAY" <<'PY'
import datetime as dt
import json
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
ledger_path = pathlib.Path(sys.argv[2])
today_text = sys.argv[3]

try:
    today = dt.date.fromisoformat(today_text)
except ValueError:
    print(f"invalid review date: {today_text!r}", file=sys.stderr)
    raise SystemExit(2)

if not config_path.is_file():
    print(f"missing Renovate config: {config_path}", file=sys.stderr)
    raise SystemExit(2)
if not ledger_path.is_file():
    print(f"missing Renovate exclusion ledger: {ledger_path}", file=sys.stderr)
    raise SystemExit(2)

config = json.loads(config_path.read_text())
ledger = ledger_path.read_text()
disabled = [
    (index, rule)
    for index, rule in enumerate(config.get("packageRules", []))
    if rule.get("enabled") is False
]
errors = []
for index, rule in disabled:
    description = rule.get("description", "")
    match = re.search(r"\bReview-by:\s*(\d{4}-\d{2}-\d{2})\b", description, re.I)
    if not match:
        errors.append(f"packageRules[{index}] has no Review-by date")
        continue
    try:
        review_by = dt.date.fromisoformat(match.group(1))
    except ValueError:
        errors.append(f"packageRules[{index}] has invalid Review-by date {match.group(1)}")
        continue
    if review_by <= today:
        errors.append(
            f"packageRules[{index}] Review-by {review_by.isoformat()} has expired"
        )
    paths = rule.get("matchFileNames", [])
    if not paths:
        errors.append(f"packageRules[{index}] has no matched paths to review")
    for path in paths:
        if path not in ledger:
            errors.append(
                f"packageRules[{index}] path {path!r} is missing from {ledger_path}"
            )

if errors:
    for error in errors:
        print(f"✗ {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    f"✓ Renovate exclusion ledger current: {len(disabled)} disabled rule(s); "
    f"review date is after {today.isoformat()}"
)
PY
