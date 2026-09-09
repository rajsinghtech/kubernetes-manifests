#!/usr/bin/env bash
set -euo pipefail

RULE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/mimir-rules.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

# Mimir's native rule files require a top-level namespace, which promtool does
# not understand. Keep each production rule as the source of truth and remove
# only that Mimir wrapper in the temporary test copy.
tested_rules=0
tested_fixtures=0

# Discover the rule files from each fixture's rule_files list. This keeps the
# runner structural: adding a *_test.yaml is enough to make it run, including
# fixtures that exercise more than one rule file. The load-path check validates
# that every new or modified rule has a fixture; older uncovered rules remain
# an intentional backlog.
while IFS= read -r test_file; do
  [ -n "$test_file" ] || continue
  fixture_name=${test_file##*/}
  rule_refs=()
  while IFS= read -r rule_ref; do
    [ -n "$rule_ref" ] && rule_refs+=("$rule_ref")
  done < <(
    sed -nE 's#^[[:space:]]*-[[:space:]]+(\.\./[^[:space:]]+\.ya?ml)[[:space:]]*$#\1#p' "$test_file"
  )

  if [ "${#rule_refs[@]}" -eq 0 ]; then
    echo "error: $test_file has no rule_files entry" >&2
    exit 1
  fi

  rewritten_fixture="$tmpdir/$fixture_name"
  cp "$test_file" "$rewritten_fixture"
  for rule_ref in "${rule_refs[@]}"; do
    rule_file=${rule_ref#../}
    case "$rule_file" in
      */*)
        echo "error: $test_file has an unsafe rule_files path: $rule_ref" >&2
        exit 1
        ;;
    esac
    source_rule="$RULE_DIR/$rule_file"
    temp_rule="$tmpdir/$rule_file"
    if [ ! -f "$source_rule" ]; then
      echo "error: $test_file references missing rule file: $rule_ref" >&2
      exit 1
    fi
    if [ ! -f "$temp_rule" ]; then
      sed -E '/^namespace:[[:space:]]+[^[:space:]]+[[:space:]]*$/d' \
        "$source_rule" >"$temp_rule"
      promtool check rules "$temp_rule"
      tested_rules=$((tested_rules + 1))
    fi
    sed "s#${rule_ref}#${temp_rule}#g" "$rewritten_fixture" >"$rewritten_fixture.next"
    mv "$rewritten_fixture.next" "$rewritten_fixture"
  done

  promtool test rules "$rewritten_fixture"
  tested_fixtures=$((tested_fixtures + 1))
done < <(find "$RULE_DIR/tests" -maxdepth 1 -type f -name '*_test.yaml' -print | sort)

echo "✓ Mimir rule fixtures: $tested_fixtures fixtures, $tested_rules rule files"
