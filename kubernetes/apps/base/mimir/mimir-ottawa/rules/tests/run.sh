#!/usr/bin/env bash
set -euo pipefail

RULE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/mimir-flux-rules.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

# Mimir's native rule files require a top-level namespace, which promtool does
# not understand. Keep the production rule as the source of truth and remove
# only that Mimir wrapper in the temporary test copy.
sed '/^namespace: flux$/d' "$RULE_DIR/flux.yaml" >"$tmpdir/flux.yaml"
sed '/^namespace: node-clock$/d' "$RULE_DIR/node-clock.yaml" >"$tmpdir/node-clock.yaml"
sed "s#../flux.yaml#$tmpdir/flux.yaml#" \
  "$RULE_DIR/tests/flux_test.yaml" >"$tmpdir/flux_test.yaml"
sed "s#../node-clock.yaml#$tmpdir/node-clock.yaml#" \
  "$RULE_DIR/tests/node-clock_test.yaml" >"$tmpdir/node-clock_test.yaml"

promtool check rules "$tmpdir/flux.yaml"
promtool check rules "$tmpdir/node-clock.yaml"
promtool test rules "$tmpdir/flux_test.yaml"
promtool test rules "$tmpdir/node-clock_test.yaml"
