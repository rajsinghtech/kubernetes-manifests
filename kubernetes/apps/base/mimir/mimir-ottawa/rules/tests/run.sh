#!/usr/bin/env bash
set -euo pipefail

RULE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/mimir-rules.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

# Mimir's native rule files require a top-level namespace, which promtool does
# not understand. Keep each production rule as the source of truth and remove
# only that Mimir wrapper in the temporary test copy.
for rule in flux bhaiya-model garage node-clock velero-integrity bhaiya-workspace-image bhaiya-workspace-endpoints; do
  case "$rule" in
    flux) test_file=flux_test.yaml ;;
    bhaiya-model) test_file=bhaiya_model_test.yaml ;;
    garage) test_file=garage_test.yaml ;;
    node-clock) test_file=node-clock_test.yaml ;;
    velero-integrity) test_file=velero-integrity_test.yaml ;;
    bhaiya-workspace-image) test_file=bhaiya_workspace_image_test.yaml ;;
    bhaiya-workspace-endpoints) test_file=bhaiya_workspace_endpoints_test.yaml ;;
  esac
  sed "/^namespace: ${rule}$/d" "$RULE_DIR/${rule}.yaml" >"$tmpdir/${rule}.yaml"
  sed "s#../${rule}.yaml#$tmpdir/${rule}.yaml#" \
    "$RULE_DIR/tests/$test_file" >"$tmpdir/$test_file"
  promtool check rules "$tmpdir/${rule}.yaml"
  promtool test rules "$tmpdir/$test_file"
done

# VeleroBackupStale consumes the newest-backup recording rule from
# velero-integrity.yaml. Test the two files together so the backup enrichment
# and its one-alert-per-schedule cardinality are exercised as deployed.
sed '/^namespace: velero-integrity$/d' "$RULE_DIR/velero-integrity.yaml" >"$tmpdir/velero-integrity.yaml"
sed '/^namespace: velero-backups$/d' "$RULE_DIR/velero.yaml" >"$tmpdir/velero.yaml"
sed \
  -e "s#../velero.yaml#$tmpdir/velero.yaml#" \
  -e "s#../velero-integrity.yaml#$tmpdir/velero-integrity.yaml#" \
  "$RULE_DIR/tests/velero_stale_test.yaml" >"$tmpdir/velero_stale_test.yaml"
promtool check rules "$tmpdir/velero.yaml"
promtool check rules "$tmpdir/velero-integrity.yaml"
promtool test rules "$tmpdir/velero_stale_test.yaml"

sed '/^namespace: mimir-loader$/d' "$RULE_DIR/mimir-loader.yaml" >"$tmpdir/mimir-loader.yaml"
sed "s#../mimir-loader.yaml#$tmpdir/mimir-loader.yaml#" \
  "$RULE_DIR/tests/mimir-loader_test.yaml" >"$tmpdir/mimir-loader_test.yaml"
promtool check rules "$tmpdir/mimir-loader.yaml"
promtool test rules "$tmpdir/mimir-loader_test.yaml"
