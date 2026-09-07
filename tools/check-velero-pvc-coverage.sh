#!/usr/bin/env bash
# tools/check-velero-pvc-coverage.sh — repo-side contract: every namespace that
# declares durable volume intent in Git must appear in a Velero Schedule's
# includedNamespaces for that cluster, or in the committed exemption list.
#
# This is a CI check, not a Mimir alert: Schedule includedNamespaces are not
# exported as metrics, and a PR-time failure prevents shipping a silent gap.
#
# See kubernetes/apps/base/velero/velero/pvc-schedule-exemptions.yaml.
set -euo pipefail
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! python3 -c "import yaml" 2>/dev/null; then
  _yaml_site=$(find /workspace/.local/share/nix/root/nix/store -maxdepth 1 -name "*pyyaml*" -not -name "*.drv" -type d 2>/dev/null | head -1)
  if [ -n "$_yaml_site" ]; then
    export PYTHONPATH="${_yaml_site}/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
  fi
fi

python3 - <<'PY'
from __future__ import annotations

from pathlib import Path
import sys

import yaml

ROOT = Path.cwd()
CLUSTERS = ("ottawa", "robbinsdale", "stpetersburg")
EXEMPTIONS_PATH = ROOT / "kubernetes/apps/base/velero/velero/pvc-schedule-exemptions.yaml"


def load_docs(path: Path):
    try:
        text = path.read_text()
    except OSError as err:
        raise SystemExit(f"cannot read {path}: {err}") from err
    try:
        for doc in yaml.safe_load_all(text):
            if isinstance(doc, dict):
                yield doc
    except yaml.YAMLError as err:
        raise SystemExit(f"cannot parse {path}: {err}") from err


def is_flux_kustomization(doc: dict) -> bool:
    return (
        doc.get("kind") == "Kustomization"
        and str(doc.get("apiVersion", "")).startswith("kustomize.toolkit.fluxcd.io/")
    )


def is_velero_schedule(doc: dict) -> bool:
    return (
        doc.get("kind") == "Schedule"
        and str(doc.get("apiVersion", "")).startswith("velero.io/")
    )


def normalize_repo_path(path: str) -> Path:
    if path.startswith("./"):
        path = path[2:]
    return ROOT / path


def path_declares_durable_volume(path: Path) -> bool:
    """True when Git under the Flux path declares a PVC, VCT, or CNPG storage."""
    if not path.exists():
        return False
    files = list(path.rglob("*.yaml")) + list(path.rglob("*.yml"))
    for file_path in files:
        for doc in load_docs(file_path):
            kind = doc.get("kind")
            if kind == "PersistentVolumeClaim":
                return True
            spec = doc.get("spec")
            if isinstance(spec, dict) and spec.get("volumeClaimTemplates"):
                return True
            if (
                kind == "Cluster"
                and str(doc.get("apiVersion", "")).startswith("postgresql.cnpg.io/")
            ):
                storage = spec.get("storage") if isinstance(spec, dict) else None
                wal = spec.get("walStorage") if isinstance(spec, dict) else None
                if isinstance(storage, dict) and storage.get("size"):
                    return True
                if isinstance(wal, dict) and wal.get("size"):
                    return True
    return False


def scheduled_namespaces(cluster: str) -> set[str]:
    covered: set[str] = set()
    schedule_dir = ROOT / f"kubernetes/apps/{cluster}/velero/schedules"
    if not schedule_dir.is_dir():
        return covered
    for path in sorted(schedule_dir.glob("*.yaml")) + sorted(schedule_dir.glob("*.yml")):
        for doc in load_docs(path):
            if not is_velero_schedule(doc):
                continue
            template = (doc.get("spec") or {}).get("template") or {}
            included = template.get("includedNamespaces") or []
            if not isinstance(included, list):
                continue
            for name in included:
                if isinstance(name, str) and name:
                    covered.add(name)
    return covered


def pvc_namespaces(cluster: str) -> set[str]:
    found: set[str] = set()
    cluster_root = ROOT / f"kubernetes/apps/{cluster}"
    for path in cluster_root.rglob("*.yaml"):
        for doc in load_docs(path):
            if not is_flux_kustomization(doc):
                continue
            spec = doc.get("spec") or {}
            target = spec.get("targetNamespace")
            source_path = spec.get("path")
            if not isinstance(target, str) or not target:
                continue
            if not isinstance(source_path, str) or not source_path:
                continue
            if path_declares_durable_volume(normalize_repo_path(source_path)):
                found.add(target)
    return found


def load_exemptions() -> dict[str, dict[str, str]]:
    """cluster -> {namespace: reason}."""
    if not EXEMPTIONS_PATH.is_file():
        raise SystemExit(f"missing exemption list: {EXEMPTIONS_PATH}")
    docs = list(load_docs(EXEMPTIONS_PATH))
    if not docs:
        raise SystemExit(f"empty exemption list: {EXEMPTIONS_PATH}")
    doc = docs[0]
    if doc.get("kind") != "VeleroPVCScheduleExemptions":
        raise SystemExit(
            f"{EXEMPTIONS_PATH}: expected kind VeleroPVCScheduleExemptions, "
            f"got {doc.get('kind')!r}"
        )
    raw = doc.get("exemptions")
    if not isinstance(raw, list) or not raw:
        raise SystemExit(f"{EXEMPTIONS_PATH}: exemptions must be a non-empty list")

    out: dict[str, dict[str, str]] = {c: {} for c in CLUSTERS}
    for idx, entry in enumerate(raw):
        if not isinstance(entry, dict):
            raise SystemExit(f"{EXEMPTIONS_PATH}: exemptions[{idx}] must be a mapping")
        cluster = entry.get("cluster")
        namespace = entry.get("namespace")
        reason = entry.get("reason")
        if cluster not in CLUSTERS:
            raise SystemExit(
                f"{EXEMPTIONS_PATH}: exemptions[{idx}].cluster must be one of {CLUSTERS}"
            )
        if not isinstance(namespace, str) or not namespace:
            raise SystemExit(f"{EXEMPTIONS_PATH}: exemptions[{idx}].namespace required")
        if not isinstance(reason, str) or not reason.strip():
            raise SystemExit(
                f"{EXEMPTIONS_PATH}: exemptions[{idx}] ({cluster}/{namespace}) "
                "needs a non-empty reason"
            )
        if namespace in out[cluster]:
            raise SystemExit(
                f"{EXEMPTIONS_PATH}: duplicate exemption {cluster}/{namespace}"
            )
        out[cluster][namespace] = " ".join(reason.split())
    return out


def main() -> int:
    exemptions = load_exemptions()
    failures: list[str] = []
    stale: list[str] = []

    for cluster in CLUSTERS:
        pvc_ns = pvc_namespaces(cluster)
        covered = scheduled_namespaces(cluster)
        exempt = exemptions[cluster]

        for namespace in sorted(pvc_ns - covered - set(exempt)):
            failures.append(
                f"{cluster}/{namespace}: declares a PVC/VCT/CNPG volume in Git "
                f"but is in no Velero Schedule and has no exemption"
            )

        for namespace in sorted(set(exempt) - pvc_ns):
            # Covered-by-schedule + exempt is also stale: exemption no longer needed.
            stale.append(
                f"{cluster}/{namespace}: exemption has no matching Git-declared "
                f"PVC namespace on this cluster (remove or fix the entry)"
            )
        for namespace in sorted(set(exempt) & covered):
            stale.append(
                f"{cluster}/{namespace}: exempted but also listed in a Schedule "
                f"(drop the exemption or the schedule membership)"
            )

    if failures or stale:
        print("velero PVC schedule coverage check failed:", file=sys.stderr)
        for line in failures + stale:
            print(f"  {line}", file=sys.stderr)
        if failures:
            print(
                "  add a Schedule includedNamespaces entry, or document the "
                "decision in "
                "kubernetes/apps/base/velero/velero/pvc-schedule-exemptions.yaml",
                file=sys.stderr,
            )
        return 1

    covered_total = sum(len(scheduled_namespaces(c)) for c in CLUSTERS)
    exempt_total = sum(len(exemptions[c]) for c in CLUSTERS)
    print(
        f"✓ velero PVC schedule coverage "
        f"(schedules cover namespaces; {exempt_total} documented exemptions)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
