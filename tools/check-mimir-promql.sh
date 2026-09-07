#!/usr/bin/env bash
# Validate every Mimir rule input with one pinned Prometheus parser.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROM_VERSION=3.14.0
PROM_ARCHIVE="prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
PROM_SHA256=f665c6da19eb7ba399c915d30c7d9793c9b417bf8a749b504bc470678631478d
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/cos-promtool/${PROM_VERSION}"
DOWNLOAD_ATTEMPTS=3

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "error: sha256sum or shasum is required to verify promtool" >&2
    return 1
  fi
}

promtool_path() {
  if [ -n "${PROMTOOL_BIN:-}" ]; then
    [ -x "$PROMTOOL_BIN" ] || {
      echo "error: PROMTOOL_BIN is not executable: $PROMTOOL_BIN" >&2
      return 1
    }
    "$PROMTOOL_BIN" --version 2>&1 | grep -F "version ${PROM_VERSION}" >/dev/null || {
      echo "error: PROMTOOL_BIN must be Prometheus ${PROM_VERSION}" >&2
      return 1
    }
    printf '%s\n' "$PROMTOOL_BIN"
    return 0
  fi

  if command -v promtool >/dev/null 2>&1; then
    local installed
    installed=$(command -v promtool)
    if "$installed" --version 2>&1 | grep -F "version ${PROM_VERSION}" >/dev/null; then
      printf '%s\n' "$installed"
      return 0
    fi
    echo "notice: ignoring installed promtool because it is not Prometheus ${PROM_VERSION}" >&2
  fi

  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64) ;;
    *)
      echo "error: pinned promtool download supports Linux x86_64; set PROMTOOL_BIN to Prometheus ${PROM_VERSION} on this platform" >&2
      return 1
      ;;
  esac

  local archive="$CACHE_ROOT/$PROM_ARCHIVE"
  local extracted="$CACHE_ROOT/prometheus-${PROM_VERSION}.linux-amd64/promtool"
  mkdir -p "$CACHE_ROOT"
  if [ ! -f "$archive" ] || [ "$(sha256 "$archive")" != "$PROM_SHA256" ]; then
    local attempt tmp curl_output curl_status last_error=""
    for ((attempt = 1; attempt <= DOWNLOAD_ATTEMPTS; attempt++)); do
      tmp="$archive.part.$$.$attempt"
      curl_output=""
      if curl_output=$(curl --fail --silent --show-error --location \
        --retry 3 --retry-all-errors --connect-timeout 15 --max-time 120 \
        "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PROM_ARCHIVE}" \
        -o "$tmp" 2>&1); then
        if [ "$(sha256 "$tmp")" = "$PROM_SHA256" ]; then
          mv "$tmp" "$archive"
          break
        fi
        last_error="archive checksum mismatch (possibly truncated or corrupt response)"
      else
        curl_status=$?
        last_error="curl exit ${curl_status}: ${curl_output:-no curl diagnostics}"
      fi
      rm -f "$tmp"
      if [ "$attempt" -lt "$DOWNLOAD_ATTEMPTS" ]; then
        echo "notice: promtool download attempt $attempt/$DOWNLOAD_ATTEMPTS failed: $last_error; retrying" >&2
      fi
    done
    if [ ! -f "$archive" ] || [ "$(sha256 "$archive")" != "$PROM_SHA256" ]; then
      echo "error: NETWORK/tool acquisition failed for pinned Prometheus ${PROM_VERSION} after ${DOWNLOAD_ATTEMPTS} attempts" >&2
      echo "error: $last_error" >&2
      echo "error: no Mimir rule parsing was attempted" >&2
      return 1
    fi
  fi
  if [ ! -x "$extracted" ]; then
    tar -xzf "$archive" -C "$CACHE_ROOT"
  fi
  [ -x "$extracted" ] || {
    echo "error: promtool was not found after extracting $archive" >&2
    return 1
  }
  printf '%s\n' "$extracted"
}

PROMTOOL=$(promtool_path)
RULE_DIR="$ROOT/kubernetes/apps/base/mimir/mimir-ottawa/rules"
status=0

rule_name() {
  local file="$1" line="$2"
  awk -v stop="$line" '
    NR > stop { exit }
    /^[[:space:]]*-[[:space:]]+(alert|record):[[:space:]]*/ {
      name=$0
      sub(/^[^:]*:[[:space:]]*/, "", name)
      sub(/[[:space:]]*#.*/, "", name)
    }
    END { print (name == "" ? "(document-level)" : name) }
  ' "$file"
}

while IFS= read -r file; do
  # Mimir's native namespace wrapper is not part of Prometheus rulefmt. The
  # temporary copy keeps production files authoritative without weakening the
  # check applied to their groups and expressions.
  temp=$(mktemp)
  sed '/^namespace:[[:space:]][^[:space:]]*[[:space:]]*$/d' "$file" >"$temp"
  output=""
  if ! output=$("$PROMTOOL" check rules "$temp" 2>&1); then
    relative=${file#"$ROOT/"}
    # Prefer promtool's source-location line. A later expression location also
    # contains numbers, so a greedy match would select that inner location and
    # lose the rule's YAML line.
    line=$(printf '%s\n' "$output" | sed -n 's#^[^:]*:[[:space:]]*\([0-9][0-9]*\):[0-9][0-9]*:.*#\1#p' | head -1)
    if [ -n "$line" ]; then
      # The parser line refers to the temporary copy, which intentionally has
      # the Mimir namespace wrapper removed. Use that same copy for context so
      # the reported rule line stays aligned.
      context=$(rule_name "$temp" "$line")
    else
      context="(document-level; no rule line reported)"
    fi
    echo "Mimir rule parse failed" >&2
    echo "file: $relative" >&2
    echo "rule: $context" >&2
    echo "$output" >&2
    status=1
  fi
  rm -f "$temp"
done < <(find "$RULE_DIR" -maxdepth 1 -type f -name '*.yaml' -print | sort)

if [ "$status" -ne 0 ]; then
  exit 1
fi
echo "✓ Mimir PromQL valid: $(find "$RULE_DIR" -maxdepth 1 -type f -name '*.yaml' | wc -l | tr -d ' ') rule files (Prometheus ${PROM_VERSION})"
