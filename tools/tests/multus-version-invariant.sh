#!/usr/bin/env bash
# Exercise the real version-sync checker against isolated aligned and split
# repository fixtures. This deliberately does not change the checkout under
# test, and it does not require a live cluster.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT INT TERM

repo="$fixture_root/repo"
mkdir -p "$repo"
git -C "$ROOT" archive -o "$fixture_root/repo.tar" HEAD
tar -xf "$fixture_root/repo.tar" -C "$repo"

# Make the fixture's two image references agree with each cluster's raw
# manifest URL. The immutable digests are irrelevant to this version-only
# invariant, so the fixture preserves them while changing only the tags.
python3 - "$repo" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
for cluster in ("ottawa", "robbinsdale", "stpetersburg"):
    base = root / f"kubernetes/apps/base/kube-system/cilium-{cluster}/app"
    kustomization = base / "kustomization.yaml"
    text = kustomization.read_text()
    version = re.search(r"/multus-cni/(v\d+\.\d+\.\d+)/", text).group(1)
    patch = kustomization if cluster == "robbinsdale" else base / "patch-multus.yaml"
    content = patch.read_text()
    content, count = re.subn(
        r"(multus-cni:)v\d+\.\d+\.\d+-thick",
        rf"\g<1>{version}-thick",
        content,
    )
    if count != 2:
        raise SystemExit(f"{patch}: expected two Multus image tags, changed {count}")
    patch.write_text(content)
PY

run_check() {
    local output_file="$1"
    set +e
    (cd "$repo" && env -u CI tools/check-versions.sh) >"$output_file" 2>&1
    local status=$?
    set -e
    return "$status"
}

aligned_output="$fixture_root/aligned.out"
if ! run_check "$aligned_output"; then
    echo "aligned Multus fixture unexpectedly failed:" >&2
    cat "$aligned_output" >&2
    exit 1
fi

# Split only Ottawa's daemon image after the aligned run. The production check
# must reject this exact partial-revert shape and identify the daemon artifact.
python3 - "$repo/kubernetes/apps/base/kube-system/cilium-ottawa/app/patch-multus.yaml" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
prefix, daemon = text.split("- name: kube-multus", 1)
daemon, count = re.subn(
    r"(?m)^(\s+image:\s+ghcr\.io/k8snetworkplumbingwg/multus-cni:)v\d+\.\d+\.\d+-thick",
    r"\g<1>v0.0.0-thick",
    daemon,
    count=1,
)
if count != 1:
    raise SystemExit(f"{path}: could not split the daemon image")
path.write_text(prefix + "- name: kube-multus" + daemon)
PY

mismatch_output="$fixture_root/mismatch.out"
if run_check "$mismatch_output"; then
    echo "mismatched Multus fixture unexpectedly passed" >&2
    cat "$mismatch_output" >&2
    exit 1
fi
grep -q "Multus ottawa: coupled artifacts differ" "$mismatch_output"
grep -q "daemon: 0.0.0" "$mismatch_output"

printf '%s\n' "✓ Multus invariant fixtures: aligned passes; Ottawa daemon split fails"
