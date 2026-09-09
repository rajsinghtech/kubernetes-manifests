#!/usr/bin/env bash
set -uo pipefail

if [ -n "${MIMIR_RULE_DIR:-}" ]; then
  RULE_DIR="$MIMIR_RULE_DIR"
else
  RULE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fi
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/mimir-rules.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

# Mimir's native rule files require a top-level namespace, which promtool does
# not understand. Keep each production rule as the source of truth and remove
# only that Mimir wrapper in the temporary test copy.
tested_rules=0
tested_fixtures=0
failure_names=()
failure_logs=()

record_failure() {
  local fixture_name="$1"
  local failure_log="$2"
  failure_names+=("$fixture_name")
  failure_logs+=("$failure_log")
}

record_message_failure() {
  local fixture_name="$1"
  local message="$2"
  local failure_log="$tmpdir/failure-${#failure_logs[@]}.log"
  printf '%s\n' "$message" >"$failure_log"
  record_failure "$fixture_name" "$failure_log"
}

# Discover the rule files from each fixture's rule_files list. This keeps the
# runner structural: adding a *_test.yaml is enough to make it run, including
# fixtures that exercise more than one rule file. The load-path check validates
# that every new or modified rule has a fixture; older uncovered rules remain
# an intentional backlog.
while IFS= read -r test_file; do
  [ -n "$test_file" ] || continue
  fixture_name=${test_file##*/}
  tested_fixtures=$((tested_fixtures + 1))
  rule_refs=()
  while IFS= read -r rule_ref; do
    [ -n "$rule_ref" ] && rule_refs+=("$rule_ref")
  done < <(
    sed -nE 's#^[[:space:]]*-[[:space:]]+(\.\./[^[:space:]]+\.ya?ml)[[:space:]]*$#\1#p' "$test_file"
  )

  if [ "${#rule_refs[@]}" -eq 0 ]; then
    record_message_failure "$fixture_name" "error: $test_file has no rule_files entry"
    continue
  fi

  rewritten_fixture="$tmpdir/$fixture_name"
  if ! cp "$test_file" "$rewritten_fixture" 2>"$tmpdir/copy-$tested_fixtures.log"; then
    record_failure "$fixture_name" "$tmpdir/copy-$tested_fixtures.log"
    continue
  fi
  fixture_failed=0
  for rule_ref in "${rule_refs[@]}"; do
    rule_file=${rule_ref#../}
    case "$rule_file" in
      */*)
        record_message_failure "$fixture_name" \
          "error: $test_file has an unsafe rule_files path: $rule_ref"
        fixture_failed=1
        break
        ;;
    esac
    source_rule="$RULE_DIR/$rule_file"
    temp_rule="$tmpdir/$rule_file"
    if [ ! -f "$source_rule" ]; then
      record_message_failure "$fixture_name" \
        "error: $test_file references missing rule file: $rule_ref"
      fixture_failed=1
      break
    fi
    if [ ! -f "$temp_rule" ]; then
      if ! sed -E '/^namespace:[[:space:]]+[^[:space:]]+[[:space:]]*$/d' \
        "$source_rule" >"$temp_rule" 2>"$tmpdir/sed-$tested_fixtures.log"; then
        record_failure "$fixture_name" "$tmpdir/sed-$tested_fixtures.log"
        fixture_failed=1
        break
      fi
      rule_check_log="$tmpdir/check-$tested_fixtures-$tested_rules.log"
      if promtool check rules "$temp_rule" >"$rule_check_log" 2>&1; then
        cat "$rule_check_log"
      else
        rule_status=$?
        printf '\n[ promtool check rules exited %d ]\n' "$rule_status" >>"$rule_check_log"
        rm -f -- "$temp_rule"
        record_failure "$fixture_name" "$rule_check_log"
        fixture_failed=1
        break
      fi
      tested_rules=$((tested_rules + 1))
    fi
    if ! sed "s#${rule_ref}#${temp_rule}#g" "$rewritten_fixture" \
      >"$rewritten_fixture.next" 2>"$tmpdir/rewrite-$tested_fixtures.log"; then
      record_failure "$fixture_name" "$tmpdir/rewrite-$tested_fixtures.log"
      fixture_failed=1
      break
    fi
    if ! mv "$rewritten_fixture.next" "$rewritten_fixture"; then
      record_message_failure "$fixture_name" "error: could not rewrite $test_file"
      fixture_failed=1
      break
    fi
  done

  if [ "$fixture_failed" -ne 0 ]; then
    continue
  fi

  fixture_log="$tmpdir/test-$tested_fixtures.log"
  if promtool test rules "$rewritten_fixture" >"$fixture_log" 2>&1; then
    cat "$fixture_log"
  else
    fixture_status=$?
    printf '\n[ promtool test rules exited %d ]\n' "$fixture_status" >>"$fixture_log"
    record_failure "$fixture_name" "$fixture_log"
  fi
done < <(find "$RULE_DIR/tests" -maxdepth 1 -type f -name '*_test.yaml' -print | sort)

if [ "${#failure_names[@]}" -ne 0 ]; then
  printf '\nMimir rule fixture failures: %d of %d fixtures\n' \
    "${#failure_names[@]}" "$tested_fixtures" >&2
  for index in "${!failure_names[@]}"; do
    printf '\n--- %s ---\n' "${failure_names[$index]}" >&2
    cat "${failure_logs[$index]}" >&2
  done
  exit 1
fi

echo "✓ Mimir rule fixtures: $tested_fixtures fixtures, $tested_rules rule files"
