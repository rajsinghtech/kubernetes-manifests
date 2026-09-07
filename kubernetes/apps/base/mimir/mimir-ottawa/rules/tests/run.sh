#!/usr/bin/env bash
set -euo pipefail

RULE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/mimir-rules.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

# Mimir's native rule files require a top-level namespace, which promtool does
# not understand. Keep each production rule as the source of truth and remove
# only that Mimir wrapper in the temporary test copy.
for rule in flux bhaiya-model; do
  case "$rule" in
    flux) test_file=flux_test.yaml ;;
    bhaiya-model) test_file=bhaiya_model_test.yaml ;;
  esac
  sed "/^namespace: ${rule}$/d" "$RULE_DIR/${rule}.yaml" >"$tmpdir/${rule}.yaml"
  sed "s#../${rule}.yaml#$tmpdir/${rule}.yaml#" \
    "$RULE_DIR/tests/$test_file" >"$tmpdir/$test_file"
  promtool check rules "$tmpdir/${rule}.yaml"
  promtool test rules "$tmpdir/$test_file"
done
