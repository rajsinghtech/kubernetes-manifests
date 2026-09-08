#!/usr/bin/env bash
# tools/check-notification-scope.sh — keep external-source Kustomizations out
# of the GitHub commit-status Alert. Flux reports the source revision in an
# event, so a provider for this repository cannot update a commit belonging to
# another GitRepository.
#
# The cluster Kustomization labels local-source children as enabled. Any
# Kustomization whose sourceRef names another source must opt out explicitly
# with notifications.keiretsu.top/github-status=disabled.
set -euo pipefail
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep this helper usable in the same minimal environments as the version
# checker. The CI image normally already has PyYAML; the fallback matches its
# user-profile lookup when it does not.
if ! python3 -c "import yaml" 2>/dev/null; then
  _yaml_site=$(find /workspace/.local/share/nix/root/nix/store -maxdepth 1 -name "*pyyaml*" -not -name "*.drv" -type d 2>/dev/null | head -1)
  if [ -n "$_yaml_site" ]; then
    export PYTHONPATH="${_yaml_site}/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
  fi
fi

python3 - <<'PY'
from pathlib import Path
import subprocess
import sys

import yaml

ROOT = Path.cwd()
LABEL = "notifications.keiretsu.top/github-status"
locations = (
    "kubernetes/apps/ottawa",
    "kubernetes/apps/robbinsdale",
    "kubernetes/apps/stpetersburg",
)

tracked = subprocess.check_output(
    ["git", "ls-files", "-z", "--", *locations], text=False
).split(b"\0")
failures = []

for raw_path in tracked:
    if not raw_path:
        continue
    path = Path(raw_path.decode())
    if path.suffix not in {".yaml", ".yml"}:
        continue
    # git ls-files includes staged deletions. A removed manifest is no longer
    # part of the notification-scope input and must not make this checker fail
    # while its deletion is being reviewed.
    if not (ROOT / path).is_file():
        continue

    try:
        documents = yaml.safe_load_all((ROOT / path).read_text())
        for document in documents:
            if not isinstance(document, dict):
                continue
            if document.get("kind") != "Kustomization":
                continue
            if not str(document.get("apiVersion", "")).startswith(
                "kustomize.toolkit.fluxcd.io/"
            ):
                continue

            spec = document.get("spec")
            source_ref = spec.get("sourceRef") if isinstance(spec, dict) else None
            source_name = (
                source_ref.get("name")
                if isinstance(source_ref, dict)
                else None
            )
            if not source_name or source_name == "kubernetes-manifests":
                continue

            metadata = document.get("metadata")
            labels = metadata.get("labels") if isinstance(metadata, dict) else None
            if not isinstance(labels, dict) or labels.get(LABEL) != "disabled":
                name = metadata.get("name", "<unnamed>") if isinstance(metadata, dict) else "<unnamed>"
                failures.append(
                    f"{path}: {name} uses sourceRef.name={source_name!r} "
                    f"without {LABEL}=disabled"
                )
    except yaml.YAMLError as error:
        failures.append(f"{path}: cannot parse YAML: {error}")

if failures:
    print("notification scope check failed:", file=sys.stderr)
    for failure in failures:
        print(f"  {failure}", file=sys.stderr)
    sys.exit(1)
PY
