#!/usr/bin/env bash
# Focused HelmRelease schema-contract tests. These run the real checker in
# copied roots, replacing only Flate and kubeconform where a deterministic
# fixture is required. The full tools/tests/run.sh suite invokes this script.
set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$ROOT/tools"
pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
assert() {
  local label="$1"
  shift
  if "$@"; then ok "$label"; else bad "$label"; fi
}

section() { printf '\n# %s\n' "$1"; }

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT INT TERM

make_checker_root() {
  local root="$1"
  local schema_root="$root/tools/schemas/helm-controller-v1.6.4"
  mkdir -p "$root/tools" \
    "$schema_root" \
    "$root/clusters/common/bootstrap/flux"
  cp "$T/check-helmrelease-schema.sh" "$root/tools/check-helmrelease-schema.sh"
  cp "$T/schemas/helm-controller-v1.6.4/provenance.json" "$schema_root/provenance.json"
  cp "$T/schemas/helm-controller-v1.6.4/helmrelease-helm-v2-strict.json" \
    "$schema_root/helmrelease-helm-v2-strict.json"
  cp "$ROOT/clusters/common/bootstrap/flux/kustomization.yaml" \
    "$root/clusters/common/bootstrap/flux/kustomization.yaml"
  chmod +x "$root/tools/check-helmrelease-schema.sh"
}

section "real checker selects raw rendered multi-document output"
raw_root="$tmp_root/raw-render"
make_checker_root "$raw_root"
cat >"$raw_root/rendered.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ignored
data:
  marker: not-a-helmrelease
---
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
  values:
    arbitraryChartValue:
      futureShape: true
---
apiVersion: v1
kind: Service
metadata:
  name: ignored-too
EOF
cat >"$raw_root/tools/flate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_FLATE_ARGS:?}"
cat "${FAKE_RENDERED:?}"
EOF
cat >"$raw_root/tools/kubeconform.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
selected="${!#}"
printf '%s\n' "$*" >"${FAKE_KUBECONFORM_ARGS:?}"
python3 - "$selected" <<'PY'
import pathlib
import sys
import yaml

documents = [item for item in yaml.safe_load_all(pathlib.Path(sys.argv[1]).read_text()) if item]
if len(documents) != 1:
    raise SystemExit(f"expected one selected document, got {len(documents)}")
document = documents[0]
if document.get("kind") != "HelmRelease":
    raise SystemExit("selected document is not a HelmRelease")
if document.get("apiVersion") != "helm.toolkit.fluxcd.io/v2":
    raise SystemExit("selected HelmRelease has the wrong API version")
if document["spec"]["values"]["arbitraryChartValue"]["futureShape"] is not True:
    raise SystemExit("opaque spec.values was not preserved")
PY
printf '%s\n' 'fake kubeconform OK'
EOF
chmod +x "$raw_root/tools/flate.sh" "$raw_root/tools/kubeconform.sh"
raw_out="$raw_root/check.stdout"
raw_err="$raw_root/check.stderr"
raw_flate_args="$raw_root/flate.args"
raw_kubeconform_args="$raw_root/kubeconform.args"
(
  cd "$raw_root"
  FAKE_RENDERED="$raw_root/rendered.yaml" \
  FAKE_FLATE_ARGS="$raw_flate_args" \
  FAKE_KUBECONFORM_ARGS="$raw_kubeconform_args" \
  tools/check-helmrelease-schema.sh talos-ottawa >"$raw_out" 2>"$raw_err"
)
raw_rc=$?
assert "raw multi-document checker passes" test "$raw_rc" = 0
assert "raw Flate path is the targeted cluster" \
  grep -q -- '--path clusters/talos-ottawa/flux/config' "$raw_flate_args"
assert "raw selection passes exactly one HelmRelease with opaque values" \
  grep -q '^fake kubeconform OK$' "$raw_out"
assert "raw checker reports one validated resource" \
  grep -q 'validated 1 rendered resources' "$raw_out"

section "provenance guards"
hash_root="$tmp_root/hash-mismatch"
make_checker_root "$hash_root"
python3 - "$hash_root/tools/schemas/helm-controller-v1.6.4/provenance.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["generatedSchemaSha256"] = "0" * 64
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
hash_out="$hash_root/check.stdout"
hash_err="$hash_root/check.stderr"
(
  cd "$hash_root"
  tools/check-helmrelease-schema.sh talos-ottawa >"$hash_out" 2>"$hash_err"
)
hash_rc=$?
assert "schema hash mismatch fails" test "$hash_rc" = 1
assert "schema hash mismatch is explained" \
  grep -q 'schema artifact hash does not match provenance' "$hash_err"

pin_root="$tmp_root/pin-mismatch"
make_checker_root "$pin_root"
python3 - "$pin_root/clusters/common/bootstrap/flux/kustomization.yaml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = "flux2/manifests/install?ref=v2.9.5"
new = "flux2/manifests/install?ref=v2.9.4"
if old not in text:
    raise SystemExit("bootstrap fixture did not contain the expected Flux pin")
path.write_text(text.replace(old, new, 1))
PY
pin_out="$pin_root/check.stdout"
pin_err="$pin_root/check.stderr"
(
  cd "$pin_root"
  tools/check-helmrelease-schema.sh talos-ottawa >"$pin_out" 2>"$pin_err"
)
pin_rc=$?
assert "Flux pin mismatch fails" test "$pin_rc" = 1
assert "Flux pin mismatch is explained" \
  grep -q 'Flux bootstrap is v2.9.4, schema provenance is v2.9.5' "$pin_err"

make_gate_root() {
  local root="$1"
  local result="$2"
  mkdir -p "$root/tools" "$root/bin"
  cp "$T/check.sh" "$root/tools/check.sh"
  for helper in check-versions.sh check-notification-scope.sh \
    check-cliproxy-pi-bridge.sh check-zot-upload-affinity.sh \
    check-mimir-rules.sh check-velero-pvc-coverage.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$root/tools/$helper"
    chmod +x "$root/tools/$helper"
  done
  if [ "$result" = success ]; then
    cat >"$root/tools/check-helmrelease-schema.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SCHEMA_ARGS:?}"
exit 0
EOF
  else
    cat >"$root/tools/check-helmrelease-schema.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SCHEMA_ARGS:?}"
echo 'intentional schema checker failure' >&2
exit 9
EOF
  fi
  chmod +x "$root/tools/check-helmrelease-schema.sh"
  cat >"$root/bin/make" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_MAKE_ARGS:?}"
exit 0
EOF
  chmod +x "$root/bin/make"
}

section "check.sh target forwarding and failure propagation"
forward_root="$tmp_root/check-forward"
make_gate_root "$forward_root" success
forward_args="$forward_root/schema.args"
forward_make_args="$forward_root/make.args"
forward_out="$forward_root/check.stdout"
forward_err="$forward_root/check.stderr"
(
  cd "$forward_root"
  PATH="$forward_root/bin:$PATH" \
  FAKE_SCHEMA_ARGS="$forward_args" \
  FAKE_MAKE_ARGS="$forward_make_args" \
  tools/check.sh ot >"$forward_out" 2>"$forward_err"
)
forward_rc=$?
assert "check.sh targeted run succeeds" test "$forward_rc" = 0
assert "check.sh forwards normalized target" \
  grep -qx 'talos-ottawa' "$forward_args"
assert "check.sh forwards target to make" \
  grep -qx 'test-talos-ottawa' "$forward_make_args"
assert "check.sh targeted success is reported" \
  grep -q '^✓ render OK: talos-ottawa$' "$forward_out"

failure_root="$tmp_root/check-failure"
make_gate_root "$failure_root" failure
failure_args="$failure_root/schema.args"
failure_make_args="$failure_root/make.args"
failure_out="$failure_root/check.stdout"
failure_err="$failure_root/check.stderr"
(
  cd "$failure_root"
  PATH="$failure_root/bin:$PATH" \
  FAKE_SCHEMA_ARGS="$failure_args" \
  FAKE_MAKE_ARGS="$failure_make_args" \
  tools/check.sh ot >"$failure_out" 2>"$failure_err"
)
failure_rc=$?
assert "check.sh schema failure propagates" test "$failure_rc" = 1
assert "check.sh failure names schema step" \
  grep -q '^=== helmrelease-schema FAILED ===$' "$failure_err"
assert "check.sh failure keeps normalized target" \
  grep -qx 'talos-ottawa' "$failure_args"
assert "check.sh does not render after schema failure" \
  test ! -s "$failure_make_args"

printf '\n== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
