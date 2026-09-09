#!/usr/bin/env bash
# tools/check-generated.sh — verify every checked-in generated artifact that
# has a deterministic repository-local freshness check.
#
# This is intentionally an aggregate gate: every check runs even when an
# earlier artifact is stale, so one bad generated file cannot hide another.
# The workflow that calls this script must install Aqua first.
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_TMP="$(mktemp -d)"
trap 'rm -rf -- "$CHECK_TMP"' EXIT HUP INT TERM

failures=0

run_check() {
  local label="$1"; shift
  local output="$CHECK_TMP/output"

  if "$@" >"$output" 2>&1; then
    printf '✓ generated: %s\n' "$label"
  else
    printf '✗ generated: %s\n' "$label"
    sed -n '1,80p' "$output"
    failures=$((failures + 1))
  fi
}

check_aqua_checksums() {
  local aqua_command="${AQUA_BIN:-aqua}"
  local checksum_file="$ROOT/aqua-checksums.json"
  local before="$CHECK_TMP/aqua-checksums.json"
  local output="$CHECK_TMP/aqua.log"
  local aqua_rc=0

  if [[ "$aqua_command" == */* ]]; then
    [ -x "$aqua_command" ] || {
      echo "aqua executable not found: $aqua_command"
      return 1
    }
  elif ! command -v "$aqua_command" >/dev/null 2>&1; then
    echo "aqua executable not found; install the CI-pinned Aqua release first"
    return 1
  fi

  [ -s "$checksum_file" ] || {
    echo "missing generated file: aqua-checksums.json"
    return 1
  }
  cp "$checksum_file" "$before"

  (cd "$ROOT" && "$aqua_command" update-checksum --prune) >"$output" 2>&1 || aqua_rc=$?
  if [ "$aqua_rc" -ne 0 ]; then
    echo "aqua update-checksum failed (exit $aqua_rc):"
    sed -n '1,80p' "$output"
    cp "$before" "$checksum_file"
    return 1
  fi

  if [ ! -f "$checksum_file" ]; then
    echo "aqua update-checksum removed aqua-checksums.json"
    cp "$before" "$checksum_file"
    return 1
  fi
  if [ "$(git hash-object "$before")" != "$(git hash-object "$checksum_file")" ]; then
    echo "aqua-checksums.json is stale; regeneration would change it:"
    git --no-pager diff --no-index -- "$before" "$checksum_file" || true
    cp "$before" "$checksum_file"
    return 1
  fi

  cp "$before" "$checksum_file"
  return 0
}

check_schema_provenance() {
  python3 - \
    "$ROOT/tools/schemas/helm-controller-v1.6.4/provenance.json" \
    "$ROOT/tools/schemas/helm-controller-v1.6.4/helmrelease-helm-v2-strict.json" \
    "$ROOT/clusters/common/bootstrap/flux/kustomization.yaml" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

provenance, schema, bootstrap = map(pathlib.Path, sys.argv[1:])
lock = json.loads(provenance.read_text())
if hashlib.sha256(schema.read_bytes()).hexdigest() != lock["generatedSchemaSha256"]:
    raise SystemExit("schema artifact hash does not match provenance")
match = re.search(r"flux2/manifests/install\?ref=v([0-9.]+)", bootstrap.read_text())
if not match:
    raise SystemExit("cannot find the Flux bootstrap version")
if match.group(1) != lock["fluxVersion"]:
    raise SystemExit(
        f"Flux bootstrap is v{match.group(1)}, schema provenance is v{lock['fluxVersion']}"
    )
PY
}

# gen-inventory.sh --check regenerates into a temporary file and compares it;
# check-diagram.sh verifies each SVG's source hash and invokes the inventory
# check as part of its coverage gate.
run_check "inventory" "$ROOT/tools/gen-inventory.sh" --check
run_check "diagrams and documentation coverage" "$ROOT/tools/check-diagram.sh"
run_check "Aqua checksums" check_aqua_checksums
run_check "HelmRelease schema provenance" check_schema_provenance

if [ "$failures" -ne 0 ]; then
  printf '%d generated-data check(s) failed\n' "$failures" >&2
  exit 1
fi

printf '✓ generated data is current\n'
