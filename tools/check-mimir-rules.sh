#!/usr/bin/env bash
# Verify that every native Mimir rule has the complete load path:
# rules directory -> hashed rules ConfigMap -> content-hashed loader Job ->
# mounted loader arguments for every tenant. A YAML file that is only present
# on disk is not an alert, and a completed fixed-name Job cannot accept a rule
# update.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT"

# Match the other repository checks: PyYAML is normally in the CI image, but
# the user profile contains the pinned package in minimal local environments.
if ! python3 -c "import yaml" 2>/dev/null; then
  yaml_site="$(find /workspace/.local/share/nix/root/nix/store -maxdepth 1 -name "*pyyaml*" -not -name "*.drv" -type d 2>/dev/null | head -1)"
  if [ -n "$yaml_site" ]; then
    export PYTHONPATH="$yaml_site/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
  fi
fi

python3 - <<'PY'
from pathlib import Path
import sys

import yaml

ROOT = Path.cwd()
MIMIR = ROOT / "kubernetes/apps/base/mimir/mimir-ottawa"
RULES = MIMIR / "rules"
KUSTOMIZATION = MIMIR / "kustomization.yaml"
LOADER = MIMIR / "loader-job.yaml"
TENANTS = {"rules-ottawa", "rules-robbinsdale", "rules-stpetersburg"}
# media.yaml predates the per-file Mimir namespace convention and contains
# cluster-independent groups. Keep that existing exception explicit so a newly
# added file cannot silently omit its namespace.
LEGACY_UNNAMESPACED = {"media.yaml"}

failures = []


def fail(message):
    failures.append(message)


def read_yaml(path):
    try:
        return yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as error:
        fail(f"{path}: cannot parse YAML: {error}")
        return None


kustomization = read_yaml(KUSTOMIZATION)
generator_files = set()
loader_name_source_wired = False
if isinstance(kustomization, dict):
    generators = kustomization.get("configMapGenerator", [])
    generator = next(
        (item for item in generators if item.get("name") == "mimir-rules"),
        None,
    )
    if generator is None:
        fail(f"{KUSTOMIZATION}: missing configMapGenerator named mimir-rules")
    else:
        raw_files = generator.get("files", [])
        if not isinstance(raw_files, list):
            fail(f"{KUSTOMIZATION}: mimir-rules.files must be a list")
        else:
            generator_files = {
                Path(item).name
                for item in raw_files
                if isinstance(item, str) and item.startswith("rules/")
            }
            for item in raw_files:
                if not isinstance(item, str) or not item.startswith("rules/"):
                    fail(f"{KUSTOMIZATION}: invalid mimir-rules entry {item!r}")
    configurations = kustomization.get("configurations", [])
    if "name-reference.yaml" not in configurations:
        fail(
            f"{KUSTOMIZATION}: missing name-reference.yaml; the completed "
            "loader Job must follow the rules ConfigMap hash"
        )
    else:
        name_reference = MIMIR / "name-reference.yaml"
        document = read_yaml(name_reference)
        references = document.get("nameReference", []) if isinstance(document, dict) else []
        for reference in references:
            if not isinstance(reference, dict):
                continue
            if reference.get("kind") != "ConfigMap" or reference.get("version") != "v1":
                continue
            for field_spec in reference.get("fieldSpecs", []):
                if not isinstance(field_spec, dict):
                    continue
                if field_spec.get("kind") == "Job" and field_spec.get("path") == "metadata/name":
                    loader_name_source_wired = True
if not loader_name_source_wired:
    fail(
        f"{KUSTOMIZATION}: generated mimir-rules name is not wired to the "
        "loader Job metadata.name; completed Jobs must be content-hashed"
    )

on_disk = {path.name for path in RULES.iterdir() if path.suffix in {".yaml", ".yml"}}
missing_from_configmap = on_disk - generator_files
missing_on_disk = generator_files - on_disk
for name in sorted(missing_from_configmap):
    fail(f"rules/{name}: present on disk but absent from mimir-rules ConfigMap")
for name in sorted(missing_on_disk):
    fail(f"rules/{name}: listed in mimir-rules ConfigMap but missing from rules/")

namespaces = {}
for name in sorted(generator_files & on_disk):
    path = RULES / name
    document = read_yaml(path)
    if not isinstance(document, dict):
        fail(f"{path}: rule document must be a mapping")
        continue
    namespace = document.get("namespace")
    if not isinstance(namespace, str) or not namespace.strip():
        if name not in LEGACY_UNNAMESPACED:
            fail(f"{path}: missing non-empty Mimir namespace")
    elif namespace in namespaces:
        fail(
            f"{path}: Mimir namespace {namespace!r} is also declared by "
            f"{namespaces[namespace]}"
        )
    else:
        namespaces[namespace] = str(path)
    if not isinstance(document.get("groups"), list) or not document["groups"]:
        fail(f"{path}: groups must be a non-empty list")

loader = read_yaml(LOADER)
containers = []
if isinstance(loader, dict):
    if loader.get("metadata", {}).get("name") != "mimir-rules":
        fail(
            f"{LOADER}: source Job name must remain mimir-rules so the "
            "generated ConfigMap name reference can hash it"
        )
    containers = (
        loader.get("spec", {})
        .get("template", {})
        .get("spec", {})
        .get("containers", [])
    )
actual_tenants = {
    item.get("name")
    for item in containers
    if isinstance(item, dict) and isinstance(item.get("name"), str)
}
if actual_tenants != TENANTS:
    fail(
        f"{LOADER}: tenant loader containers are {sorted(actual_tenants)!r}, "
        f"want {sorted(TENANTS)!r}"
    )

volumes = (
    loader.get("spec", {})
    .get("template", {})
    .get("spec", {})
    .get("volumes", [])
    if isinstance(loader, dict)
    else []
)
rules_volume = next(
    (item for item in volumes if isinstance(item, dict) and item.get("name") == "rules"),
    None,
)
if not isinstance(rules_volume, dict) or rules_volume.get("configMap", {}).get("name") != "mimir-rules":
    fail(f"{LOADER}: rules volume must mount the generated mimir-rules ConfigMap")

for container in containers:
    if not isinstance(container, dict) or not isinstance(container.get("name"), str):
        continue
    name = container["name"]
    if name not in TENANTS:
        continue
    mounts = container.get("volumeMounts", [])
    if not any(
        isinstance(mount, dict)
        and mount.get("name") == "rules"
        and mount.get("mountPath") == "/rules"
        for mount in mounts
    ):
        fail(f"{LOADER}: {name} does not mount the rules volume at /rules")
    args = container.get("args", [])
    loaded = {
        Path(item).name
        for item in args
        if isinstance(item, str) and item.startswith("/rules/")
    }
    missing = generator_files - loaded
    extra = loaded - generator_files
    for rule in sorted(missing):
        fail(f"{LOADER}: {name} does not load /rules/{rule}")
    for rule in sorted(extra):
        fail(f"{LOADER}: {name} loads unlisted /rules/{rule}")

required = {
    "bhaiya-sandbox-telemetry.yaml": "bhaiya-sandbox-telemetry",
    "bhaiya-workspace-image.yaml": "bhaiya-workspace-image",
}
for filename, namespace in required.items():
    path = RULES / filename
    if filename not in generator_files:
        fail(f"{path}: required alert file is not in the ConfigMap")
    if namespaces.get(namespace) != str(path):
        fail(f"{path}: required namespace {namespace!r} is not uniquely declared there")

if failures:
    print("Mimir rule load-path check failed:", file=sys.stderr)
    for failure in failures:
        print(f"  {failure}", file=sys.stderr)
    sys.exit(1)

print(
    f"✓ Mimir rule load-path: {len(generator_files)} files, "
    f"{len(TENANTS)} tenant loaders, {len(namespaces)} unique namespaces"
)
PY
