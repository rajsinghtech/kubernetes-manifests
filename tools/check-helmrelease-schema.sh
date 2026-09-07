#!/usr/bin/env bash
# Validate rendered Flux HelmRelease v2 objects against the pinned local CRD.
# This intentionally validates Flate output, not source files: substitutions,
# overlays, and generated resource shape must be checked together.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

schema_root="$ROOT/tools/schemas/helm-controller-v1.6.4"
schema="$schema_root/helmrelease-helm-v2-strict.json"
schema_location="$schema"
provenance="$schema_root/provenance.json"
[ -s "$schema" ] || { echo "error: missing local HelmRelease schema: $schema" >&2; exit 2; }
[ -s "$provenance" ] || { echo "error: missing schema provenance: $provenance" >&2; exit 2; }

python3 - "$provenance" "$schema" "$ROOT/clusters/common/bootstrap/flux/kustomization.yaml" <<'PY'
import hashlib, json, pathlib, re, sys
provenance, schema, bootstrap = map(pathlib.Path, sys.argv[1:])
lock = json.loads(provenance.read_text())
actual = hashlib.sha256(schema.read_bytes()).hexdigest()
if actual != lock["generatedSchemaSha256"]:
    raise SystemExit("schema artifact hash does not match provenance")
match = re.search(r"flux2/manifests/install\?ref=v([0-9.]+)", bootstrap.read_text())
if not match:
    raise SystemExit("cannot find the Flux bootstrap version")
if match.group(1) != lock["fluxVersion"]:
    raise SystemExit(
        f"Flux bootstrap is v{match.group(1)}, schema provenance is v{lock['fluxVersion']}"
    )
PY

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT INT TERM
targets=(talos-ottawa talos-robbinsdale talos-stpetersburg)
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [talos-ottawa|talos-robbinsdale|talos-stpetersburg]" >&2
  exit 2
elif [ "$#" = 1 ]; then
  case "$1" in
    ot|ottawa|talos-ottawa) targets=(talos-ottawa) ;;
    rb|robbinsdale|talos-robbinsdale) targets=(talos-robbinsdale) ;;
    sp|stpetersburg|talos-stpetersburg) targets=(talos-stpetersburg) ;;
    *) echo "error: unknown cluster '$1'" >&2; exit 2 ;;
  esac
fi

total=0
for cluster in "${targets[@]}"; do
  rendered="$tmp/$cluster.yaml"
  flate_err="$tmp/$cluster-flate.err"
  selected="$tmp/$cluster-helmreleases.yaml"
  location="${cluster#talos-}"
  # `build all` emits the final chart resources for HelmReleases; it does not
  # emit the HelmRelease CRs themselves. The location application tree's
  # Kustomization artifacts retain those post-build CR documents, which are
  # the objects this CRD gate validates. The full cluster render gate below
  # remains authoritative for chart/source reconciliation failures.
  flate_rc=0
  # CI exports FLATE_BASE=main for changed-only render gates. This focused
  # schema view must inspect the existing full location tree even when the PR
  # changes only tooling, or it would legitimately emit zero app documents.
  env -u FLATE_BASE tools/flate.sh build ks --path "kubernetes/apps/$location" \
    --allow-missing-secrets --no-progress >"$rendered" 2>"$flate_err" || flate_rc=$?
  if [ ! -s "$rendered" ]; then
    echo "error: Flate emitted no rendered Kustomization output for $cluster (exit $flate_rc)" >&2
    tail -30 "$flate_err" >&2 || true
    exit 1
  fi
  # Flate can retain usable Kustomization output while reporting unrelated
  # chart/source failures in this source-only view. Do not turn that partial
  # output into a false zero-resource schema failure; tools/check.sh runs the
  # complete cluster render immediately after this focused check and reports
  # those failures there.
  count="$(python3 - "$rendered" "$selected" <<'PY'
import pathlib, sys, yaml
source, target = map(pathlib.Path, sys.argv[1:])
text = source.read_text()
try:
    # BaseLoader inspects the node tree without applying PyYAML's YAML 1.1
    # scalar constructors. Flate can legitimately emit plain values such as
    # `=` that Kubernetes' YAML decoder accepts but SafeLoader rejects.
    documents = list(yaml.load_all(text, Loader=yaml.BaseLoader))
    nodes = list(yaml.compose_all(text, Loader=yaml.BaseLoader))
except yaml.YAMLError as error:
    raise SystemExit(f"rendered Flate YAML is invalid: {error}")
if len(documents) != len(nodes):
    raise SystemExit("rendered YAML document accounting mismatch")
selected = []
for document, node in zip(documents, nodes):
    if not isinstance(document, dict) or document.get("kind") != "HelmRelease":
        continue
    api_version = document.get("apiVersion")
    if api_version != "helm.toolkit.fluxcd.io/v2":
        raise SystemExit(
            f"unsupported HelmRelease API version {api_version!r}; update the pinned schema"
        )
    selected.append(text[node.start_mark.index:node.end_mark.index])
with target.open("w") as stream:
    for document in selected:
        stream.write("---\n")
        stream.write(document)
        if not document.endswith("\n"):
            stream.write("\n")
print(len(selected))
PY
  )"
  case "$count" in ''|*[!0-9]*) echo "error: invalid HelmRelease count for $cluster: $count" >&2; exit 2;; esac
  [ "$count" -gt 0 ] || { echo "error: Flate emitted no HelmRelease v2 resources for $cluster" >&2; exit 1; }
  tools/kubeconform.sh -strict -schema-location "$schema_location" \
    -output text -summary "$selected"
  total=$((total + count))
done
echo "HelmRelease v2 schema OK (validated $total rendered resources)"
