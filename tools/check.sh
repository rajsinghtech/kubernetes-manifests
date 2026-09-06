#!/usr/bin/env bash
# tools/check.sh — the kubernetes-manifests acceptance gate for kustomize/flux.
# Prints exactly one line on success; on failure prints only the first ~50 lines
# of the failing step, so build agents don't dump full output into their context.
# Anchored to the repo root, so it runs from any cwd.
#
# The full gate renders all three clusters concurrently. If only one cluster
# changed, scope it anyway: `tools/check.sh talos-ottawa`.
#
# Usage:
#   tools/check.sh                       # full gate (render-test all clusters)
#   tools/check.sh <cluster>             # single cluster, e.g. tools/check.sh talos-ottawa
#   tools/check.sh --quick               # quick check (just syntax, no full render)
set -euo pipefail
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  tools/check.sh
  tools/check.sh <talos-ottawa|talos-robbinsdale|talos-stpetersburg>
  tools/check.sh --quick
EOF
}

QUICK=0
TARGET=""
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*) echo "unknown flag: $a" >&2; exit 2 ;;
    *)
      if [ -n "$TARGET" ]; then
        echo "error: expected at most one cluster target" >&2
        exit 2
      fi
      TARGET="$a"
      ;;
  esac
done

case "$TARGET" in
  "") ;;
  ot|ottawa|talos-ottawa) TARGET="talos-ottawa" ;;
  rb|robbinsdale|talos-robbinsdale) TARGET="talos-robbinsdale" ;;
  sp|stpetersburg|talos-stpetersburg) TARGET="talos-stpetersburg" ;;
  *)
    echo "error: unknown cluster '$TARGET' (valid: talos-ottawa, talos-robbinsdale, talos-stpetersburg)" >&2
    exit 2
    ;;
esac
if [ "$QUICK" = 1 ] && [ -n "$TARGET" ]; then
  echo "error: --quick does not accept a cluster target" >&2
  exit 2
fi

# Flate's full-tree render includes stable failures when the local source and
# render caches are cold, while CI restores those caches before running this
# gate. Compare the render with a baseline instead: a clean checkout has no
# changed resources to report, and a changed resource is still rendered and
# can fail. The cluster target also scans the location app tree because those
# files live outside the cluster-config scan root. The CI action supplies
# FLATE_BASE=main; local checkouts select the merge-base with the default
# remote (or the branch upstream as a fallback).
# Set KMAN_CHECK_FULL_TREE=1 for an intentional full-tree diagnostic run.
if [ -z "${KMAN_CHECK_FULL_TREE:-}" ] && [ -z "${FLATE_BASE:-}" ]; then
  for candidate in origin/HEAD origin/main origin/master '@{u}'; do
    if render_base="$(git merge-base HEAD "$candidate" 2>/dev/null)"; then
      export FLATE_BASE="$render_base"
      break
    fi
  done
fi

# Rendering resolves Helm/OCI chart sources through go-containerregistry, which
# reads ~/.docker/config.json. On macOS that file sets `credsStore: osxkeychain`,
# so every registry read shells out to docker-credential-osxkeychain and raises a
# keychain prompt. Prompts nobody answers fail the fetch and surface as render
# errors rather than auth errors, and the waiting turns a 2s render into ~2min —
# which then reads as a flate wedge. The gate needs no registry credentials (a
# full three-cluster render passes with an empty config), so point Docker and Helm
# at a throwaway one. Export DOCKER_CONFIG yourself to opt back in.
if [ -z "${DOCKER_CONFIG:-}" ]; then
  KMAN_DOCKER_CONFIG="$(mktemp -d)"
  trap 'rm -rf "$KMAN_DOCKER_CONFIG"' EXIT
  export DOCKER_CONFIG="$KMAN_DOCKER_CONFIG"
fi
export HELM_REGISTRY_CONFIG="${HELM_REGISTRY_CONFIG:-$DOCKER_CONFIG/helm-registry.json}"

# Flate occasionally wedges in a CPU spin instead of returning, which hangs the
# gate forever. macOS ships no coreutils `timeout`, so enable job control to put
# the render in its own process group and kill the whole group on deadline —
# signalling `make` alone would orphan the spinning flate child.
# A healthy full three-cluster render finishes in seconds, so cap at 120s: a
# wedge costs 2 minutes, not 10. Raise via KMAN_CHECK_TIMEOUT if ever needed.
CHECK_TIMEOUT="${KMAN_CHECK_TIMEOUT:-120}"

run_capped() {
  local label="$1"; shift
  local out timedout rc=0
  out="$(mktemp)"
  timedout="$(mktemp)"

  set -m
  "$@" >"$out" 2>&1 &
  local pid=$!
  set +m

  {
    sleep "$CHECK_TIMEOUT"
    printf 'yes' >"$timedout"
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 5
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  } >/dev/null 2>&1 &
  local watchdog=$!

  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  # The watchdog's timer can elapse in the gap between the render finishing and
  # this shell reaping it, which mislabels a completed render as a timeout and
  # buries the real failures under "raise the budget". A render the watchdog
  # actually killed dies from a signal, so `wait` reports 128+signum; anything
  # lower means it exited on its own and its output is trustworthy.
  if [ -s "$timedout" ] && [ "$rc" -ge 128 ]; then
    rm -f "$timedout"
    echo "=== $label TIMED OUT after ${CHECK_TIMEOUT}s ===" >&2
    echo "killed process group; raise the budget with KMAN_CHECK_TIMEOUT=<secs>" >&2
    tail -15 "$out" >&2
    rm -f "$out"
    exit 124
  fi
  rm -f "$timedout"

  if [ "$rc" -eq 0 ]; then
    rm -f "$out"
    return 0
  fi

  echo "=== $label FAILED ===" >&2
  # Render output is mostly successful objects. Surface failure context first,
  # then retain the summary tail, without flooding agent context.
  if command -v rg >/dev/null 2>&1; then
    rg -n -C 2 '✗|⊘|[Ee]rror|[Ff]ailed|blocked by' "$out" | tail -35 >&2 || true
  else
    grep -n -C 2 -E '✗|⊘|[Ee]rror|[Ff]ailed|blocked by' "$out" | tail -35 >&2 || true
  fi
  echo "--- summary tail ---" >&2
  tail -15 "$out" >&2
  echo "(showing focused diagnostics from '$*')" >&2
  rm -f "$out"
  exit 1
}

run_capped "version-sync" tools/check-versions.sh
run_capped "notification-scope" tools/check-notification-scope.sh
run_capped "cliproxy-pi-bridge" tools/check-cliproxy-pi-bridge.sh
run_capped "zot-upload-affinity" tools/check-zot-upload-affinity.sh
run_capped "mimir-rule-load-path" tools/check-mimir-rules.sh

if [ "$QUICK" = 1 ]; then
  # Quick syntax check: validate kustomize build on a representative sample
  for dir in kubernetes/apps/base/*/; do
    [ -d "$dir" ] || continue
    for app in "$dir"*/; do
      [ -d "$app" ] || continue
      run_capped "syntax: $app" kustomize build --enable-helm "$app"
    done
  done
  echo "✓ syntax OK"
  exit 0
fi

if [ -n "$TARGET" ]; then
  run_capped "render" make "test-$TARGET"
  echo "✓ render OK: $TARGET"
else
  run_capped "render" make test
  echo "✓ render OK: talos-ottawa talos-robbinsdale talos-stpetersburg"
fi
