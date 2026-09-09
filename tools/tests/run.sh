#!/usr/bin/env bash
# tools/tests/run.sh — deterministic, offline self-tests for the tools/ helpers.
# No live cluster calls: kubectl/make are stubbed on PATH; orphans/where use
# temp fixtures and read-only repo lookups. Run: tools/tests/run.sh
set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$ROOT/tools"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
# assert LABEL CMD...  -> ok when CMD succeeds (grep reads stdin via <<< herestring)
assert() { local l="$1"; shift; if "$@"; then ok "$l"; else bad "$l"; fi; }
# refute LABEL CMD...  -> ok when CMD fails
refute() { local l="$1"; shift; if "$@"; then bad "$l"; else ok "$l"; fi; }
# exits  LABEL WANT CMD... -> ok when CMD's exit code equals WANT
exits()  { local l="$1" w="$2"; shift 2; "$@" >/dev/null 2>&1; local g=$?
           if [ "$g" = "$w" ]; then ok "$l (exit $g)"; else bad "$l (want $w got $g)"; fi; }
section() { printf '\n# %s\n' "$1"; }

# ---------------------------------------------------------------- kc.sh
section "kc.sh"
stub="$(mktemp -d)"
cat >"$stub/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "KUBECONFIG=$KUBECONFIG"
echo "ARGS=$*"
exit 7
EOF
chmod +x "$stub/kubectl"

exits  "no args -> usage exit 2"   2 "$T/kc.sh"
exits  "bad alias -> exit 2"       2 "$T/kc.sh" xx get ns
assert "bad alias lists valid aliases" grep -qi 'valid:' <<<"$("$T/kc.sh" xx 2>&1)"

out="$(PATH="$stub:$PATH" "$T/kc.sh" ot -n media get pods 2>&1)"; ec=$?
assert "ot -> repo kubeconfig"     grep -q "KUBECONFIG=$ROOT/.kube/config" <<<"$out"
assert "ot -> ottawa context"      grep -q -- '--context ottawa-k8s-operator.keiretsu.ts.net' <<<"$out"
assert "ot -> args passthrough"    grep -q -- 'ARGS=--context ottawa-k8s-operator.keiretsu.ts.net -n media get pods' <<<"$out"
assert "ot -> exit code passthrough (7)" test "$ec" = 7

rbout="$(PATH="$stub:$PATH" "$T/kc.sh" rb get ns 2>&1)"
assert "rb -> robbinsdale context" grep -q 'robbinsdale-k8s-operator.keiretsu.ts.net' <<<"$rbout"

spout="$(PATH="$stub:$PATH" "$T/kc.sh" sp get nodes 2>&1)"
assert "sp -> repo kubeconfig"     grep -q "KUBECONFIG=$ROOT/.kube/config" <<<"$spout"
assert "sp -> stpetersburg context" grep -q -- '--context stpetersburg-k8s-operator.keiretsu.ts.net' <<<"$spout"
rm -rf "$stub"

# ---------------------------------------------------------------- ktriage.sh
# Stubs kubectl (reached through kc.sh's exec) and dispatches on args. Every
# call is appended to $KUBECTL_CALLS so the read-only contract is checkable.
# Oversized fixtures (100 log lines, 15 events) prove the tail/cut bounds hold;
# the degraded_* fixtures fail one section after the pod-read gate to prove a
# later failure degrades (exit 4 + inline marker) instead of reading as empty.
section "ktriage.sh"
kstub="$(mktemp -d)"
cat >"$kstub/kubectl" <<'STUB'
#!/usr/bin/env bash
[ -n "${KUBECTL_CALLS:-}" ] && printf '%s\n' "$*" >>"$KUBECTL_CALLS"
args="$*"
case "$args" in
  *--previous*) awk 'BEGIN{for(i=1;i<=100;i++)print "PREVLOG-"i}'; exit 0 ;;
  *logs*)       awk 'BEGIN{for(i=1;i<=100;i++)print "LOGLINE-"i}'; exit 0 ;;
esac
case "${KT_FIXTURE:-crash}" in
  apifail)
    case "$args" in
      *custom-columns=PHASE*) echo 'Error from server (NotFound): pods "ghost" not found' >&2; exit 1 ;;
    esac
    exit 0 ;;
  ok)
    case "$args" in
      *"get events"*)          awk 'BEGIN{for(i=1;i<=2;i++)printf "2026-07-18T00:0%d:00Z Normal Started okEVT%d container started\n",i,i}'; exit 0 ;;
      *initContainerStatuses*) exit 0 ;;
      *containerStatuses*)     printf 'web\ttrue\t0\t\t2026-07-18T00:00:00Z\t\n'; exit 0 ;;
      *conditions*)            exit 0 ;;
      *custom-columns=PHASE*)  printf 'Running node-1 10.3.2.9 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
  degraded_events)
    # summary/states/conditions succeed; only the events query fails.
    case "$args" in
      *"get events"*)          echo 'Error from server: etcdserver: request timed out' >&2; exit 1 ;;
      *initContainerStatuses*) exit 0 ;;
      *containerStatuses*)     printf 'web\ttrue\t0\t\t2026-07-18T00:00:00Z\t\n'; exit 0 ;;
      *conditions*)            exit 0 ;;
      *custom-columns=PHASE*)  printf 'Running node-1 10.3.2.9 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
  degraded_state)
    # summary succeeds; the container-states query fails; events still succeed.
    case "$args" in
      *"get events"*)          awk 'BEGIN{for(i=1;i<=2;i++)printf "2026-07-18T00:0%d:00Z Normal Pulled EVT%d image pulled\n",i,i}'; exit 0 ;;
      *initContainerStatuses*) exit 0 ;;
      *containerStatuses*)     echo 'Error from server: unable to return a response' >&2; exit 1 ;;
      *conditions*)            exit 0 ;;
      *custom-columns=PHASE*)  printf 'Pending node-1 <none> 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
  multiline)
    # a multi-line terminated message must not spawn phantom container rows.
    case "$args" in
      *"get events"*)          exit 0 ;;
      *initContainerStatuses*) exit 0 ;;
      *containerStatuses*)     printf 'app\tfalse\t0\tError\t\tpanic: boom\ngoroutine 1 [running]:\nmain.main()\n'; exit 0 ;;
      *conditions*)            exit 0 ;;
      *custom-columns=PHASE*)  printf 'Running node-1 10.3.2.9 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
  *)
    case "$args" in
      *"get events"*)          awk 'BEGIN{for(i=1;i<=15;i++)printf "2026-07-18T00:%02d:00Z Warning BackOff EVT%02d back-off restarting failed container\n",i,i}'; exit 0 ;;
      *initContainerStatuses*) printf 'setup\ttrue\t0\tCompleted\t\t\n'; exit 0 ;;
      *containerStatuses*)     printf 'app\tfalse\t5\tCrashLoopBackOff\t\tback-off 5m0s restarting failed container=app\n'; exit 0 ;;
      *conditions*)            printf 'Ready\tContainersNotReady\tcontainers with unready status: [app]\nContainersReady\tContainersNotReady\tcontainers with unready status: [app]\n'; exit 0 ;;
      *custom-columns=PHASE*)  printf 'Running node-3 10.3.1.5 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$kstub/kubectl"
calls="$kstub/calls"

# --- bad usage (no cluster call needed) ---
exits  "no args -> usage exit 2"        2 "$T/ktriage.sh"
exits  "missing pod arg -> exit 2"      2 "$T/ktriage.sh" ot media
exits  "too many args -> exit 2"        2 "$T/ktriage.sh" ot media crashpod extra
assert "usage names ktriage"            grep -qi 'usage:.*ktriage' <<<"$("$T/ktriage.sh" 2>&1)"
exits  "bad cluster -> kc.sh exit 2"    2 "$T/ktriage.sh" xx media crashpod

# --- crashing / restarted container ---
: >"$calls"
cout="$(PATH="$kstub:$PATH" KT_FIXTURE=crash KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media crashpod 2>&1)"; cec=$?
assert "crash -> exit 0"                test "$cec" = 0
assert "crash -> summary phase"         grep -q 'PHASE=Running' <<<"$cout"
assert "crash -> container state"       grep -q 'app .*restarts=5 .*CrashLoopBackOff' <<<"$cout"
assert "crash -> init container state"  grep -q 'setup .*Completed' <<<"$cout"
assert "crash -> non-True condition"    grep -q 'Ready .*ContainersNotReady' <<<"$cout"
# events clamped to latest 10 despite 15 emitted
assert "crash -> latest event kept"     grep -q 'EVT15' <<<"$cout"
refute "crash -> 11th-from-end dropped" grep -q 'EVT05' <<<"$cout"
assert "crash -> exactly 10 events"     test "$(grep -c 'EVT[0-9]' <<<"$cout")" = 10
# current logs clamped to tail 20 despite 100 emitted
assert "crash -> last log line kept"    grep -q 'LOGLINE-100' <<<"$cout"
assert "crash -> 20th-from-end kept"    grep -q 'LOGLINE-81' <<<"$cout"
refute "crash -> 21st-from-end dropped" grep -q 'LOGLINE-80' <<<"$cout"
assert "crash -> exactly 20 cur logs"   test "$(grep -c 'LOGLINE-' <<<"$cout")" = 20
# previous logs shown for restarted container, also clamped
assert "crash -> previous logs shown"   grep -q 'PREVLOG-100' <<<"$cout"
assert "crash -> exactly 20 prev logs"  test "$(grep -c 'PREVLOG-' <<<"$cout")" = 20
assert "crash -> output <= 80 lines"    test "$(grep -c . <<<"$cout")" -le 80

# --- read-only contract (recorded verbs) ---
assert "calls include get pod"          grep -q 'get pod' "$calls"
assert "calls include logs"             grep -q 'logs' "$calls"
assert "calls use --request-timeout=10s" grep -q -- '--request-timeout=10s' "$calls"
assert "restarted -> uses --previous"   grep -q -- '--previous' "$calls"
refute "never dumps -o yaml"            grep -q -- '-o yaml' "$calls"
refute "never dumps -o json"            grep -qE -- '-o json($| )' "$calls"
refute "never touches secrets"          grep -qi 'secret' "$calls"
for v in apply delete exec patch create replace edit scale drain cordon rollout annotate label cp attach port-forward set; do
  refute "never runs verb: $v"          grep -qw "$v" "$calls"
done

# --- healthy / no-restart container ---
: >"$calls"
hout="$(PATH="$kstub:$PATH" KT_FIXTURE=ok KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media healthypod 2>&1)"; hec=$?
assert "healthy -> exit 0"              test "$hec" = 0
assert "healthy -> container shown"     grep -q 'web .*ready=true' <<<"$hout"
refute "healthy -> no crashloop"        grep -q 'CrashLoopBackOff' <<<"$hout"
refute "healthy -> no previous logs"    grep -q 'PREVLOG' <<<"$hout"
refute "healthy -> no --previous call"  grep -q -- '--previous' "$calls"
assert "healthy -> current logs clamped" test "$(grep -c 'LOGLINE-' <<<"$hout")" = 20
assert "healthy -> compact (<=40 ln)"   test "$(grep -c . <<<"$hout")" -le 40

# --- API failure -> nonzero, no misleading partial success ---
: >"$calls"
aout="$(PATH="$kstub:$PATH" KT_FIXTURE=apifail KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media ghost 2>&1)"; aec=$?
assert "api failure -> nonzero exit"    test "$aec" != 0
assert "api failure -> reports error"   grep -qiE 'error|not found|cannot read' <<<"$aout"
refute "api failure -> no log section"  grep -q 'LOGLINE' <<<"$aout"
refute "api failure -> no fake summary" grep -q 'PHASE=' <<<"$aout"

# --- later-section failure -> nonzero + inline marker, never mislabeled ---
# events query fails after the gate: must read "unavailable", not "(none)".
: >"$calls"
eout="$(PATH="$kstub:$PATH" KT_FIXTURE=degraded_events KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media evpod 2>&1)"; eec=$?
assert "events-fail -> exit 4 (partial)"      test "$eec" = 4
assert "events-fail -> summary still shown"   grep -q 'PHASE=Running' <<<"$eout"
assert "events-fail -> container still shown" grep -q 'web .*ready=true' <<<"$eout"
assert "events-fail -> unavailable marker"    grep -q 'events.*:' <<<"$eout"
assert "events-fail -> section marked"        grep -q '(unavailable' <<<"$eout"
refute "events-fail -> not mislabeled none"   grep -q '(none)' <<<"$eout"

# container-states query fails: marker + degrade, but later sections still run.
: >"$calls"
sfout="$(PATH="$kstub:$PATH" KT_FIXTURE=degraded_state KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media stpod 2>&1)"; sfec=$?
assert "state-fail -> exit 4 (partial)"       test "$sfec" = 4
assert "state-fail -> summary still shown"    grep -q 'PHASE=Pending' <<<"$sfout"
assert "state-fail -> states unavailable"     grep -q 'containers: (unavailable' <<<"$sfout"
assert "state-fail -> events still emitted"   grep -q 'EVT1' <<<"$sfout"

# --- multi-line container message must not spawn phantom rows / log fetches ---
: >"$calls"
mout="$(PATH="$kstub:$PATH" KT_FIXTURE=multiline KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media mlpod 2>&1)"; mec=$?
assert "multiline -> exit 0"                  test "$mec" = 0
assert "multiline -> real row kept"           grep -q 'app ready=false .*Error' <<<"$mout"
assert "multiline -> exactly one state row"   test "$(grep -c 'ready=' <<<"$mout")" = 1
refute "multiline -> no phantom row printed"  grep -q 'goroutine' <<<"$mout"
assert "multiline -> logs fetched for app"    grep -q -- '-c app' "$calls"
refute "multiline -> no phantom log fetch"    grep -q -- 'main.main' "$calls"
rm -rf "$kstub"

# ---------------------------------------------------------------- app.sh
section "app.sh"
list1="$("$T/app.sh" --list)"; list2="$("$T/app.sh" --list)"
assert "--list nonempty"           test -n "$list1"
assert "--list stable across runs" test "$list1" = "$list2"
assert "--list sorted+unique"      test "$list1" = "$(printf '%s\n' "$list1" | sort -u)"
assert "--list has immich row"     grep -q 'immich .*kubernetes/apps/base/immich/immich.* ottawa' <<<"$list1"
# shellcheck disable=SC2016  # $2 is an awk field, not a shell expansion
assert "--list rows well-formed"   awk 'NF<3 || $2 !~ /^kubernetes\/apps\/base\// {b=1} END{exit b+0}' <<<"$list1"
subout="$( (cd /tmp && "$T/app.sh" immich) 2>&1 )"
assert "substring immich (from /tmp)"  grep -q 'base manifests:' <<<"$subout"
exits  "substring no-match -> exit 1"  1 sh -c "cd /tmp && '$T/app.sh' zzz-nope-xyz"

# ---------------------------------------------------------------- refs.sh
section "refs.sh"
refs="$( (cd /tmp && "$T/refs.sh" immich) )"; ec=$?
assert "immich -> exit 0"          test "$ec" = 0
assert "immich -> nonempty"        test -n "$refs"
assert "output sorted+unique"      test "$refs" = "$(printf '%s\n' "$refs" | sort -u)"
allfiles=1; while IFS= read -r p; do [ -f "$ROOT/$p" ] || allfiles=0; done <<<"$refs"
assert "output lines are file paths" test "$allfiles" = 1
# PID-suffixed at runtime so the query literal can't self-match this tracked
# test file via refs.sh's content search (a static token would live here).
nomatch="zzz-refs-nomatch-$$"
exits  "no-match -> exit 1"         1 "$T/refs.sh" "$nomatch"
exits  "no args -> exit 2"          2 "$T/refs.sh"

# ---------------------------------------------------------------- orphans.sh
section "orphans.sh"
fx="$(mktemp -d)"
mkdir -p "$fx/clean" "$fx/dirty"
cat >"$fx/clean/kustomization.yaml" <<'EOF'
resources:
  - a.yaml
  - b.yaml
  - https://example.com/remote.yaml
EOF
: >"$fx/clean/a.yaml"; : >"$fx/clean/b.yaml"
exits  "clean fixture -> exit 0"    0 "$T/orphans.sh" "$fx/clean"
assert "clean fixture -> no output" test -z "$("$T/orphans.sh" "$fx/clean" 2>&1)"

mkdir -p "$fx/parent/child"
cat >"$fx/parent/kustomization.yaml" <<'EOF'
resources:
  - child/live.yaml
EOF
: >"$fx/parent/child/kustomization.yaml"
: >"$fx/parent/child/live.yaml"
exits  "direct parent reference -> not orphaned" 0 "$T/orphans.sh" "$fx/parent"

cat >"$fx/dirty/kustomization.yaml" <<'EOF'
resources:
  - present.yaml
  - gone.yaml
  - https://example.com/remote.yaml
patches:
  - path: patchme.yaml
  - patch: |-
      - op: add
        path: /metadata/labels/x
    target:
      kind: Deployment
EOF
: >"$fx/dirty/present.yaml"; : >"$fx/dirty/patchme.yaml"
: >"$fx/dirty/orphan.yaml"; : >"$fx/dirty/leftover.dec.yaml"
dout="$("$T/orphans.sh" "$fx/dirty" 2>&1)"; dec=$?
assert "dirty -> exit 1"                test "$dec" = 1
assert "flags missing resource"         grep -q 'MISSING.*gone.yaml' <<<"$dout"
assert "flags unlisted sibling"         grep -q 'UNLISTED.*orphan.yaml' <<<"$dout"
refute "ignores remote URL"             grep -q 'remote.yaml' <<<"$dout"
refute "ignores inline JSON6902 path"   grep -q '/metadata/labels' <<<"$dout"
refute "ignores generated .dec.yaml"    grep -q 'leftover.dec.yaml' <<<"$dout"
refute "listed patch not flagged"       grep -q 'patchme.yaml' <<<"$dout"
rm -rf "$fx"

# ---------------------------------------------------------------- where.sh
section "where.sh"
whereout="$( (cd /tmp && "$T/where.sh" 'resources' kubernetes/apps/base/immich/immich/app/kustomization.yaml) )"
assert "root-anchored repo-relative path (from /tmp)" grep -q 'resources' <<<"$whereout"
upperwhere="$( (cd /tmp && "$T/where.sh" 'RESOURCES' kubernetes/apps/base/immich/immich/app/kustomization.yaml) )"
assert "pattern matching is case-insensitive" test -n "$upperwhere"
exits  "missing file -> exit 1"     1 "$T/where.sh" foo /no/such/file.xyz

# ---------------------------------------------------------------- flate.sh (pinned binary; no network)
section "flate.sh (stubbed binary)"
fstub="$(mktemp -d)"
flate_pin="$(sed -n 's|.*home-operations/flate/action@v\([0-9][0-9.]*\).*|\1|p' \
  "$ROOT/.github/workflows/flate.yaml" | sort -u | head -1)"
flate_calls="$fstub/calls"
cat >"$fstub/flate" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo "flate version $flate_pin"
  exit 0
fi
printf '%s\n' "\$*" >>"\$FLATE_CALLS"
EOF
chmod +x "$fstub/flate"

: >"$flate_calls"
KMAN_FLATE_BIN="$fstub/flate" FLATE_CALLS="$flate_calls" "$T/flate.sh" test all --no-progress
assert "pinned override -> missing-secret safety" \
  grep -q '^test all --no-progress --allow-missing-secrets$' "$flate_calls"

: >"$flate_calls"
KMAN_FLATE_BIN="$fstub/flate" FLATE_CALLS="$flate_calls" \
  "$T/flate.sh" diff all --allow-missing-secrets
assert "explicit missing-secret flag -> no duplicate" \
  grep -q '^diff all --allow-missing-secrets$' "$flate_calls"
assert "CI action pin matches wrapper fixture" grep -q "home-operations/flate/action@v$flate_pin" "$ROOT/.github/workflows/flate.yaml"

cat >"$fstub/old-flate" <<'EOF'
#!/usr/bin/env bash
echo "flate version 0.4.10"
EOF
chmod +x "$fstub/old-flate"
oldout="$(KMAN_FLATE_BIN="$fstub/old-flate" "$T/flate.sh" test all 2>&1)"; oldec=$?
assert "mismatched override -> exit 2" test "$oldec" = 2
assert "mismatch names required version" grep -q "CI requires $flate_pin" <<<"$oldout"

: >"$flate_calls"
KMAN_FLATE_BIN="$fstub/flate" FLATE_CALLS="$flate_calls" make -s -C "$ROOT" test
assert "full make gate -> three renders" test "$(wc -l <"$flate_calls" | tr -d ' ')" = 3

: >"$flate_calls"
KMAN_FLATE_BIN="$fstub/flate" FLATE_CALLS="$flate_calls" FLATE_BASE=baseline \
  make -s -C "$ROOT" test
assert "baseline make gate -> six renders" test "$(wc -l <"$flate_calls" | tr -d ' ')" = 6
for cluster in talos-ottawa talos-robbinsdale talos-stpetersburg; do
  assert "full make gate -> $cluster" grep -q -- "--path clusters/$cluster/flux/config" "$flate_calls"
  assert "baseline make gate -> $cluster complete context" \
    grep -q -- "--path clusters/$cluster" "$flate_calls"
done
refute "baseline make gate -> no incomplete location-only scan" \
  grep -q -- '--path kubernetes/apps/' "$flate_calls"

# A renderer failure from the complete context render must propagate through
# make. The real Flate parser is exercised by the integration gate, while this
# offline test stays networkless.
cat >"$fstub/flate" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo "flate version $flate_pin"
  exit 0
fi
case "\$*" in
  *'--path clusters/talos-ottawa --no-progress'*) exit 1 ;;
esac
printf '%s\\n' "\$*" >>"\$FLATE_CALLS"
EOF
chmod +x "$fstub/flate"
KMAN_FLATE_BIN="$fstub/flate" FLATE_CALLS="$flate_calls" FLATE_BASE=baseline \
  make -s -C "$ROOT" test-talos-ottawa >/dev/null 2>&1; context_ec=$?
assert "complete context render failure -> make fails" test "$context_ec" != 0
rm -rf "$fstub"

# ---------------------------------------------------------------- check.sh (stubbed make; no real render)
section "check.sh (stubbed make)"
mstub="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' >"$mstub/make"; chmod +x "$mstub/make"
gate_root="$(mktemp -d)"
mkdir -p "$gate_root/tools"
cp "$T/check.sh" "$gate_root/tools/check.sh"
for helper in check-mimir-promql.sh check-versions.sh check-notification-scope.sh \
  check-cliproxy-pi-bridge.sh check-zot-upload-affinity.sh \
  check-mimir-rules.sh check-velero-pvc-coverage.sh \
  check-helmrelease-schema.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$gate_root/tools/$helper"
  chmod +x "$gate_root/tools/$helper"
done
sout="$(PATH="$mstub:$PATH" "$gate_root/tools/check.sh" 2>/dev/null)"; sec=$?
assert "success -> exit 0"              test "$sec" = 0
assert "success prints exactly 1 line"  test "$(printf '%s\n' "$sout" | grep -c .)" = 1
assert "success line format"            grep -q '^✓ render OK:' <<<"$sout"
exits  "unknown cluster -> exit 2"      2 "$gate_root/tools/check.sh" nope
exits  "multiple clusters -> exit 2"    2 "$gate_root/tools/check.sh" ot rb
exits  "quick + cluster -> exit 2"      2 "$gate_root/tools/check.sh" --quick ot
assert "help -> concise usage"           grep -q '^Usage:' <<<"$("$gate_root/tools/check.sh" --help)"
aliasout="$(PATH="$mstub:$PATH" "$gate_root/tools/check.sh" ot 2>/dev/null)"
assert "short cluster alias accepted"   grep -q '^✓ render OK: talos-ottawa$' <<<"$aliasout"
rm -rf "$gate_root"

# ---------------------------------------------------------------- Mimir rule completeness replay
section "Mimir rule completeness replay"
exits "km#2809 missing-group condition is detected" 0 \
  python3 "$ROOT/kubernetes/apps/base/monitoring/mimir-rule-completeness/tests/test_rule_completeness.py"

# A completed gate must reap every watchdog timer descendant. Use an isolated
# temporary gate root so this test exercises the real run_capped implementation
# without allowing a sleep stub to affect repository prerequisite checks.
# Every timer announces its PID through one shared FIFO; each isolated helper
# consumes exactly the timer belonging to its own run_capped invocation. The
# parent opens the render FIFO before starting the gate and uses read -t only as
# a bounded supervisor, never as synchronization by elapsed sleep.
watchdog_tmp="$(mktemp -d)"
mkdir -p "$watchdog_tmp/tools" "$watchdog_tmp/stub"
cp "$T/check.sh" "$watchdog_tmp/tools/check.sh"
for helper in check-mimir-promql.sh check-versions.sh check-notification-scope.sh \
  check-cliproxy-pi-bridge.sh check-zot-upload-affinity.sh \
  check-mimir-rules.sh check-velero-pvc-coverage.sh \
  check-helmrelease-schema.sh; do
  cat >"$watchdog_tmp/tools/$helper" <<'EOF'
#!/usr/bin/env bash
IFS= read -r _ <"$WATCHDOG_READY"
exit 0
EOF
  chmod +x "$watchdog_tmp/tools/$helper"
done
watchdog_ready="$watchdog_tmp/ready"
watchdog_release="$watchdog_tmp/release"
watchdog_pids="$watchdog_tmp/pids"
render_ready="$watchdog_tmp/render-ready"
render_go="$watchdog_tmp/render-go"
mkfifo "$watchdog_ready" "$watchdog_release" "$render_ready" "$render_go"
cat >"$watchdog_tmp/stub/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >>"$WATCHDOG_PIDS"
printf '%s\n' "$$" >"$WATCHDOG_READY"
IFS= read -r _ <"$WATCHDOG_RELEASE"
EOF
chmod +x "$watchdog_tmp/stub/sleep"
cat >"$watchdog_tmp/stub/make" <<'EOF'
#!/usr/bin/env bash
IFS= read -r timer_pid <"$WATCHDOG_READY"
printf '%s\n' "$timer_pid" >"$RENDER_READY"
IFS= read -r _ <"$RENDER_GO"
EOF
chmod +x "$watchdog_tmp/stub/make"
# Keep a reader/writer open before starting children so no readiness event can
# be lost between the watchdog's announcement and the consumer's open.
exec 7<>"$watchdog_ready"
exec 8<>"$render_ready"
watchdog_sleep_pid=""
stop_fixture_pid() {
  local fixture_pid="$1"
  kill -TERM "$fixture_pid" 2>/dev/null || true
  if kill -0 "$fixture_pid" 2>/dev/null; then
    kill -KILL "$fixture_pid" 2>/dev/null || true
  fi
}
WATCHDOG_READY="$watchdog_ready" WATCHDOG_RELEASE="$watchdog_release" \
  WATCHDOG_PIDS="$watchdog_pids" RENDER_READY="$render_ready" \
  RENDER_GO="$render_go" FLATE_BASE=baseline \
  PATH="$watchdog_tmp/stub:$PATH" "$watchdog_tmp/tools/check.sh" ot \
  >"$watchdog_tmp/output" 2>&1 &
watchdog_check_pid=$!
if IFS= read -r -t 30 watchdog_sleep_pid <&8; then
  printf 'go\n' >"$render_go"
  wait "$watchdog_check_pid"; watchdog_ec=$?
else
  watchdog_ec=124
  stop_fixture_pid "$watchdog_check_pid"
  while IFS= read -r fixture_pid; do
    [ -n "$fixture_pid" ] || continue
    stop_fixture_pid "$fixture_pid"
  done <"$watchdog_pids"
  wait "$watchdog_check_pid" 2>/dev/null || true
fi
assert "completed gate -> watchdog exits successfully" test "$watchdog_ec" = 0
watchdog_unreaped=0
while IFS= read -r fixture_pid; do
  [ -n "$fixture_pid" ] || continue
  if kill -0 "$fixture_pid" 2>/dev/null; then
    watchdog_unreaped=1
  fi
done <"$watchdog_pids"
assert "completed gate -> every watchdog timer reaped" test "$watchdog_unreaped" = 0
exec 7>&-
exec 8>&-
rm -rf "$watchdog_tmp"

printf '#!/usr/bin/env bash\necho "render Error: boom"; exit 1\n' >"$mstub/make"; chmod +x "$mstub/make"
fout="$(PATH="$mstub:$PATH" "$T/check.sh" 2>/dev/null)"; fec=$?
assert "failure -> exit 1"              test "$fec" = 1
assert "failure -> nothing on stdout"   test -z "$fout"

# A wedged render must be killed rather than hang the gate forever. The stub
# backgrounds a child and waits on it, mirroring make->flate: signalling only
# the direct child would leave the real spinning flate orphaned. Coordinate on
# the child's start, termination, and the check process's completion instead
# of inferring any of them from elapsed wall-clock time. The 30-second reads
# below are failure bounds; the production two-second watchdog remains the
# behavior under test.
wedge_ready="$mstub/ready"
wedge_stopped="$mstub/stopped"
wedge_result="$mstub/result"
wedge_output="$mstub/output"
wedge_pid_file="$mstub/pid"
mkfifo "$wedge_ready" "$wedge_stopped" "$wedge_result"
wedge_gate_root="$mstub/gate"
mkdir -p "$wedge_gate_root/tools"
cp "$T/check.sh" "$wedge_gate_root/tools/check.sh"
for helper in check-mimir-promql.sh check-versions.sh check-notification-scope.sh \
  check-cliproxy-pi-bridge.sh check-zot-upload-affinity.sh \
  check-mimir-rules.sh check-velero-pvc-coverage.sh \
  check-helmrelease-schema.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$wedge_gate_root/tools/$helper"
  chmod +x "$wedge_gate_root/tools/$helper"
done
cat >"$mstub/make" <<'EOF'
#!/usr/bin/env bash
set -u

child_pid=""
stop_child() {
  kill -TERM "$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
  printf 'stopped\n' >"$WEDGE_STOPPED"
  exit 143
}

trap stop_child TERM INT
sleep 300 &
child_pid="$!"
printf '%s\n' "$child_pid" >"$WEDGE_PID_FILE"
printf '%s\n' "$child_pid" >"$WEDGE_READY"
wait "$child_pid"
EOF
chmod +x "$mstub/make"

# Keep FIFO endpoints open before starting the fixture so no readiness event
# can be lost between the child announcing it and the parent consuming it.
exec 7<>"$wedge_ready"
exec 8<>"$wedge_stopped"
exec 9<>"$wedge_result"
(
  set +e
  WEDGE_PID_FILE="$wedge_pid_file" WEDGE_READY="$wedge_ready" \
    WEDGE_STOPPED="$wedge_stopped" PATH="$mstub:$PATH" KMAN_CHECK_TIMEOUT=2 \
    FLATE_BASE=baseline "$wedge_gate_root/tools/check.sh" >"$wedge_output" 2>&1 &
  wedge_check_pid="$!"
  trap 'kill -TERM -"$wedge_check_pid" 2>/dev/null || kill -TERM "$wedge_check_pid" 2>/dev/null || true' TERM INT
  wait "$wedge_check_pid"
  wedge_check_ec="$?"
  printf '%s\n' "$wedge_check_ec" >"$wedge_result"
) &
wedge_runner_pid="$!"
wedge_pid=""
wedge_ec=125
if IFS= read -r -t 30 wedge_pid <&7; then
  if IFS= read -r -t 30 wedge_stopped <&8; then
    IFS= read -r -t 30 wedge_ec <&9 || wedge_ec=125
  fi
fi
if [ "$wedge_ec" = 125 ]; then
  # The wrapper forwards TERM to check.sh; also terminate the known fixture
  # child in case the failure happened before the watchdog reached it.
  kill -TERM "$wedge_runner_pid" 2>/dev/null || true
  if [ -n "$wedge_pid" ]; then
    kill -TERM "$wedge_pid" 2>/dev/null || true
    kill -KILL "$wedge_pid" 2>/dev/null || true
  fi
fi
wait "$wedge_runner_pid" 2>/dev/null || true
wedge_output_text="$(cat "$wedge_output" 2>/dev/null || true)"
assert "timeout -> exit 124"            test "$wedge_ec" = 124
assert "timeout -> reports the budget"  grep -q 'TIMED OUT after 2s' <<<"$wedge_output_text"
assert "timeout -> child announced start" test -n "$wedge_pid"
if [ -n "$wedge_pid" ]; then
  refute "timeout -> grandchild reaped"   kill -0 "$wedge_pid" 2>/dev/null
else
  bad "timeout -> grandchild reaped (child never announced start)"
fi
exec 7>&-
exec 8>&-
exec 9>&-
rm -f "$wedge_ready" "$wedge_stopped" "$wedge_result" "$wedge_output" "$wedge_pid_file"
rm -rf "$mstub"

# ---------------------------------------------------------------- flate.sh env pruning
section "flate.sh environment pruning"
fstub="$(mktemp -d)"
pinned="$flate_pin"
# A stand-in for the UPX-packed release: it refuses to run once the environment
# grows past what the real stub tolerates, which is exactly the failure mode.
cat >"$fstub/flate" <<EOF
#!/usr/bin/env bash
if [ "\$(env | wc -l | tr -d ' ')" -gt 120 ]; then exit 139; fi
if [ "\$1" = "--version" ]; then echo "flate version $pinned"; exit 0; fi
echo "flate ran with \$(env | wc -l | tr -d ' ') env vars"
EOF
chmod +x "$fstub/flate"

# Build an environment big enough to trip the threshold in flate.sh.
bigenv() {
  local -a e=()
  local i
  for i in $(seq 1 400); do e+=("PAD$i=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"); done
  env "${e[@]}" KMAN_FLATE_BIN="$fstub/flate" "$@"
}

assert "huge env -> flate.sh still resolves the version" \
  grep -q 'flate ran with' <<<"$(bigenv "$T/flate.sh" test --path x 2>&1)"
assert "huge env -> child sees a pruned environment" \
  test "$(bigenv "$T/flate.sh" test --path x 2>&1 | grep -oE '[0-9]+ env vars' | grep -oE '^[0-9]+')" -le 120
assert "KMAN_FLATE_KEEP_ENV=1 disables pruning" \
  grep -q 'does not report\|unknown' \
  <<<"$(bigenv KMAN_FLATE_KEEP_ENV=1 "$T/flate.sh" test --path x 2>&1)"
# A normal-sized environment must be passed through untouched.
assert "small env -> no pruning applied" \
  grep -q 'flate ran with' \
  <<<"$(env -i PATH="$PATH" HOME="$HOME" KMAN_FLATE_BIN="$fstub/flate" \
        "$T/flate.sh" test --path x 2>&1)"
rm -rf "$fstub"

# ---------------------------------------------------------------- gen-inventory.sh
# The inventory is generated, so the only way it can be wrong is by being
# unregenerated. --check is what the diagram gate calls to prove it is not.
section "gen-inventory.sh"
exits  "unknown argument -> exit 2"  2 "$T/gen-inventory.sh" --nope
exits  "--check passes on a clean tree" 0 "$T/gen-inventory.sh" --check
assert "stdout mode emits the generated header" \
  grep -q 'Generated by tools/gen-inventory.sh' <<<"$("$T/gen-inventory.sh" - 2>/dev/null)"
assert "stdout mode lists every location" test 3 = "$(
  "$T/gen-inventory.sh" - 2>/dev/null | grep -c '^## .* — .talos-' )"
# Serials identify physical hardware and must never reach a published doc.
refute "inventory omits install-disk serials" \
  grep -qiE 'serial' <<<"$("$T/gen-inventory.sh" - 2>/dev/null)"

inv="$ROOT/docs/reference/inventory.md"
if [ -f "$inv" ]; then
  invbak="$(mktemp)"; cp "$inv" "$invbak"
  printf '# tampered\n' >"$inv"
  exits  "--check fails when the committed copy drifts" 1 "$T/gen-inventory.sh" --check
  assert "drift report names the fix" \
    grep -q 'run tools/gen-inventory.sh' <<<"$("$T/gen-inventory.sh" --check 2>&1)"
  cp "$invbak" "$inv"; rm -f "$invbak"
  exits  "--check passes again once restored" 0 "$T/gen-inventory.sh" --check
fi

# ---------------------------------------------------------------- check-generated.sh
section "check-generated.sh"
gstub="$(mktemp -d)"
cat >"$gstub/aqua" <<'EOF'
#!/usr/bin/env bash
if [ "${AQUA_FIXTURE:-}" = stale ]; then
  printf '\n' >> aqua-checksums.json
fi
EOF
chmod +x "$gstub/aqua"

gchecks_hash="$(git hash-object "$ROOT/aqua-checksums.json")"
exits "clean generated artifacts pass" 0 \
  env PATH="$gstub:$PATH" "$T/check-generated.sh"
invbak3="$(mktemp)"; cp "$inv" "$invbak3"
printf '# stale generated inventory\n' >"$inv"
bothout="$(AQUA_FIXTURE=stale PATH="$gstub:$PATH" "$T/check-generated.sh" 2>&1)"; both_ec=$?
assert "two stale generators -> nonzero" test "$both_ec" = 1
assert "two stale generators -> reports inventory" grep -q '✗ generated: inventory' <<<"$bothout"
assert "two stale generators -> reports Aqua" grep -q 'aqua-checksums.json is stale' <<<"$bothout"
assert "two stale generators -> reaches later checks" \
  grep -q '✓ generated: HelmRelease schema provenance' <<<"$bothout"
cp "$invbak3" "$inv"; rm -f "$invbak3"
gout="$(AQUA_FIXTURE=stale PATH="$gstub:$PATH" "$T/check-generated.sh" 2>&1)"; gec=$?
assert "stale generator -> nonzero" test "$gec" = 1
assert "stale generator -> names Aqua artifact" grep -q 'aqua-checksums.json is stale' <<<"$gout"
assert "stale generator -> reports a diff" grep -q '^[-+]' <<<"$gout"
assert "stale generator -> restores the worktree" \
  test "$(git hash-object "$ROOT/aqua-checksums.json")" = "$gchecks_hash"
rm -rf "$gstub"

# ---------------------------------------------------------------- check-diagram.sh
section "check-diagram.sh"
dtmp="$(mktemp -d)"

printf '# no diagram here\n' >"$dtmp/none.md"
exits  "markdown without a dot block -> exit 2" 2 "$T/check-diagram.sh" "$dtmp/none.md"
exits  "missing file -> exit 2"                 2 "$T/check-diagram.sh" "$dtmp/nope.md"

# Syntax: a broken graph must be rejected even though it has no secrets.
printf '# t\n\n```dot\ndigraph g { a -> ; }\n```\n' >"$dtmp/badsyntax.md"
assert "broken graph -> SYNTAX finding" \
  grep -q '^SYNTAX' <<<"$("$T/check-diagram.sh" "$dtmp/badsyntax.md" 2>&1)"

# Secrets: each of these must be caught on its own.
leak() { printf '# t\n\n```dot\ndigraph g { n [label="%s"]; }\n```\n' "$1" >"$dtmp/leak.md"
         grep -q '^SECRETS' <<<"$("$T/check-diagram.sh" "$dtmp/leak.md" 2>&1)"; }
assert "catches tailscale auth key"  leak 'tskey-auth-kXaBcDeFgH-1234567890abcdef'
assert "catches AWS access key id"   leak 'AKIAIOSFODNN7EXAMPLE'
assert "catches GitHub token"        leak 'ghp_0123456789abcdefghijklmnopqrstuvwxyz'
assert "catches JWT"                 leak 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0'
assert "catches bcrypt hash"         leak '$2y$10$abcdefghijklmnopqrstuvABCDEFGHIJKLMNOPQRSTUV'
assert "catches e-mail address"      leak 'operator@example.com'
assert "catches MAC address"         leak '38:05:25:36:56:39'
assert "catches disk serial"         leak 'serial: 50026B7686F78587'
assert "catches public IP"           leak '203.0.113.9 is fine but 8.8.8.8 is not'
assert "catches tailnet CGNAT IP"    leak 'peer at 100.101.102.103'
assert "catches SOPS ciphertext"     leak 'ENC[AES256_GCM,data:abc]'
assert "catches a long opaque blob"  leak 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXphYmNkZWZnaGlqa2xtbm9wcXI='
refute "allows RFC1918 addresses"    leak '192.168.169.25 and 10.3.0.0/16'
refute "allows image digests"        leak 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
refute "allows the documented SOPS fingerprint" \
                                     leak 'FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5'
# A deep repo path shares base64's alphabet and trips the blob detector at
# exactly 48 chars. Paths must pass; anything with a non-word segment must not.
refute "allows a long repo path"     leak 'see kubernetes/apps/base/garage/garage/garagecluster.yaml'
assert "still catches base64 with slashes" \
                                     leak 'aGVsbG8gd29ybGQgdGhpcyBpcyBhIHNlY3JldCB0b2tlbg/QUJDRA/EFGH'

# The allow escape hatch suppresses a finding on that line only.
printf '# t\n\n```dot\ndigraph g { n [label="ops@example.com"]; // diagram-check: allow\n}\n```\n' \
  >"$dtmp/allow.md"
refute "diagram-check: allow suppresses a finding" \
  grep -q '^SECRETS' <<<"$("$T/check-diagram.sh" "$dtmp/allow.md" 2>&1)"

# Reverse coverage: a diagram must not claim an app that is not deployed.
# Both declaration styles are supported — the historical app_<id> node prefix
# and the `// diagram-apps:` comment the prose-labelled diagrams use.
printf 'digraph g { app_definitely_not_deployed; }\n' >"$dtmp/stale.dot"
assert "flags stale app_ node" \
  grep -q 'names an app that is not deployed' <<<"$("$T/check-diagram.sh" "$dtmp/stale.dot" 2>&1)"
printf '// diagram-apps: definitely-not-deployed\ndigraph g { a -> b; }\n' >"$dtmp/declared.dot"
assert "flags stale diagram-apps declaration" \
  grep -q 'names an app that is not deployed: definitely-not-deployed' \
  <<<"$("$T/check-diagram.sh" "$dtmp/declared.dot" 2>&1)"
printf '// diagram-apps: cilium\ndigraph g { a -> b; }\n' >"$dtmp/live.dot"
refute "a deployed app in diagram-apps is not flagged" \
  grep -q 'names an app that is not deployed' <<<"$("$T/check-diagram.sh" "$dtmp/live.dot" 2>&1)"

# Forward coverage is deliberately split across two corpora, and this is the
# test that the split is real rather than decorative.
#
#   locations / cluster settings / Talos machines -> must appear in a
#     HAND-maintained doc (diagrams, architecture.md, README). Requiring these
#     of the generated inventory would just be the gate confirming its own
#     output, so the inventory is excluded from that corpus.
#   namespaces / Flux Kustomization names -> checked against the corpus that
#     DOES include the generated inventory, because that is what carries the
#     long tail; freshness is enforced separately by the INVENTORY check.
#
# So blanking the inventory must report the namespaces and apps as undocumented
# while leaving the hand-covered facts alone. If the two ever collapse into one
# corpus, the refutes below start failing.
if [ -f "$inv" ]; then
  invbak2="$(mktemp)"; cp "$inv" "$invbak2"
  printf '# emptied for the coverage test\n' >"$inv"
  cov="$("$T/check-diagram.sh" 2>&1)"
  assert "missing inventory -> COVERAGE findings" grep -q '^COVERAGE' <<<"$cov"
  assert "requires namespaces"       grep -q 'namespace not documented:' <<<"$cov"
  assert "requires Flux app names"   grep -q 'app not documented:' <<<"$cov"
  assert "also reports the inventory as stale" grep -q '^INVENTORY' <<<"$cov"
  # The other half of the split: these are covered by hand, so losing the
  # generated file must not implicate them.
  refute "locations are not blamed on the generated inventory" \
    grep -q 'location not documented' <<<"$cov"
  refute "Talos machines are not blamed on it either" \
    grep -q 'node not documented' <<<"$cov"
  cp "$invbak2" "$inv"; rm -f "$invbak2"
  exits  "gate passes again once the inventory is restored" 0 "$T/check-diagram.sh"
fi

# Staleness: the committed SVG must prove which source it came from, because
# GitHub shows the picture and nobody diffs an SVG by eye. Both the light and
# the dark rendering carry the stamp.
firstsvg="$(find "$ROOT/docs/diagrams" -maxdepth 1 -name '*.svg' ! -name '*.dark.svg' 2>/dev/null | sort | head -1)"
if [ -n "$firstsvg" ] && [ -s "$firstsvg" ]; then
  svgbak="$(mktemp)"; cp "$firstsvg" "$svgbak"
  # Replace the whole digest, not its first character: a real sha256 starting
  # with 0 would make a single-character edit a no-op and the test vacuous.
  sed 's/diagram-source-sha256: [0-9a-f]*/diagram-source-sha256: '"$(printf '0%.0s' $(seq 64))"'/' \
    "$svgbak" >"$firstsvg"
  assert "mismatched SVG stamp -> STALE finding" \
    grep -q '^STALE' <<<"$("$T/check-diagram.sh" 2>&1)"
  cp "$svgbak" "$firstsvg"; rm -f "$svgbak"
  assert "restored SVG passes again" test -z \
    "$("$T/check-diagram.sh" 2>&1 | grep '^STALE' || true)"

  darksvg="${firstsvg%.svg}.dark.svg"
  if [ -s "$darksvg" ]; then
    darkbak="$(mktemp)"; cp "$darksvg" "$darkbak"
    sed 's/diagram-source-sha256: [0-9a-f]*/diagram-source-sha256: '"$(printf '0%.0s' $(seq 64))"'/' \
      "$darkbak" >"$darksvg"
    assert "dark rendering is stamped and checked too" \
      grep -q '^STALE' <<<"$("$T/check-diagram.sh" 2>&1)"
    cp "$darkbak" "$darksvg"; rm -f "$darkbak"
  fi
fi

# Links: a diagram the README never shows is a diagram nobody maintains.
orphan="$ROOT/docs/diagrams/zz-orphan-selftest.svg"
printf '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n' >"$orphan"
assert "unlinked diagram -> LINKS finding" \
  grep -q '^LINKS.*never links it' <<<"$("$T/check-diagram.sh" 2>&1)"
rm -f "$orphan"

# The real documentation set must pass every check.
exits  "the committed docs pass the gate" 0 "$T/check-diagram.sh"
assert "success prints one ✓ line" \
  grep -q '^✓ diagram OK:' <<<"$("$T/check-diagram.sh" 2>/dev/null)"
rm -rf "$dtmp"

# ---------------------------------------------------------------- check-velero-pvc-coverage.sh
# Offline: mutate a real Schedule fixture, prove the guard fires, restore it.
section "check-velero-pvc-coverage.sh"
exits  "current tree passes coverage gate" 0 "$T/check-velero-pvc-coverage.sh"
assert "success mentions exemptions" \
  grep -q 'documented exemptions' <<<"$("$T/check-velero-pvc-coverage.sh" 2>/dev/null)"

hsbak="$(mktemp)"
cp "$ROOT/kubernetes/apps/ottawa/velero/schedules/home-backup.yaml" "$hsbak"
python3 - "$ROOT/kubernetes/apps/ottawa/velero/schedules/home-backup.yaml" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1])
docs = [d for d in yaml.safe_load_all(p.read_text()) if isinstance(d, dict)]
for doc in docs:
    if doc.get("kind") == "Schedule":
        doc.setdefault("spec", {}).setdefault("template", {})["includedNamespaces"] = ["tinyauth"]
p.write_text("---\n" + "\n---\n".join(yaml.safe_dump(d, sort_keys=False) for d in docs))
PY
exits  "dropping home from schedule fails the gate" 1 "$T/check-velero-pvc-coverage.sh"
assert "failure names ottawa/home" \
  grep -q 'ottawa/home' <<<"$("$T/check-velero-pvc-coverage.sh" 2>&1 || true)"
cp "$hsbak" "$ROOT/kubernetes/apps/ottawa/velero/schedules/home-backup.yaml"
rm -f "$hsbak"
exits  "restored schedule passes again" 0 "$T/check-velero-pvc-coverage.sh"

# ---------------------------------------------------------------- HelmRelease schema
# Offline fixture tests use the repository-pinned kubeconform wrapper and the
# complete Flux HelmRelease v2 schema. No rendered cluster or live API is used.
section "HelmRelease v2 schema"
hrfixture="$(mktemp -d)"
cat >"$hrfixture/valid.yaml" <<'EOF'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: fixture
  namespace: flux-system
spec:
  interval: 5m
  chart:
    spec:
      chart: fixture
      sourceRef:
        kind: HelmRepository
        name: fixture
  upgrade:
    remediation:
      strategy: rollback
  values:
    arbitraryChartValue:
      futureShape: true
EOF
cat >"$hrfixture/invalid-enum.yaml" <<'EOF'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: fixture
spec:
  interval: 5m
  chart:
    spec:
      chart: fixture
      sourceRef: {kind: HelmRepository, name: fixture}
  upgrade:
    remediation:
      strategy: retry
EOF
cat >"$hrfixture/invalid-field.yaml" <<'EOF'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: fixture
spec:
  interval: 5m
  chart:
    spec:
      chart: fixture
      sourceRef: {kind: HelmRepository, name: fixture}
  upgrade:
    remediation:
      unexpectedField: true
EOF
schema="$ROOT/tools/schemas/helm-controller-v1.6.4/helmrelease-helm-v2-strict.json"
exits "valid HelmRelease and opaque values pass" 0 \
  "$T/kubeconform.sh" -strict -schema-location "$schema" "$hrfixture/valid.yaml"
exits "invalid remediation enum fails" 1 \
  "$T/kubeconform.sh" -strict -schema-location "$schema" "$hrfixture/invalid-enum.yaml"
exits "invalid CRD field fails" 1 \
  "$T/kubeconform.sh" -strict -schema-location "$schema" "$hrfixture/invalid-field.yaml"
rm -rf "$hrfixture"

schema_contract_out="$(mktemp)"
if "$T/tests/helmrelease-schema.sh" >"$schema_contract_out" 2>&1; then
  ok "real HelmRelease checker contract regressions"
else
  bad "real HelmRelease checker contract regressions"
  sed -n '1,160p' "$schema_contract_out"
fi
rm -f "$schema_contract_out"

# ---------------------------------------------------------------- summary
printf '\n== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
