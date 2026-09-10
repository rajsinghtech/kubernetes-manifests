#!/usr/bin/env python3
"""Expose whether internal-registry images used by running pods are still pullable.

The probe intentionally uses only the Kubernetes read API and OCI manifest
HEAD requests.  It never pulls an image, reads a layer, or changes either
cluster state or registry state.  Only the configured internal registry is
checked; external images are outside this detector's retention boundary.  A
404 is reported as ``missing``; every other HTTP, DNS, TLS, or Kubernetes error
is ``unknown`` so a connectivity problem can never masquerade as image
deletion.
"""

from __future__ import annotations

import http.server
import json
import os
import ssl
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


API_BASE = "https://kubernetes.default.svc"
API_PATH = "/api/v1/pods"
PVC_API_PATH = "/api/v1/persistentvolumeclaims"
PV_API_PATH = "/api/v1/persistentvolumes"
VELERO_SCHEDULE_API_PATH = "/apis/velero.io/v1/schedules"
SERVICE_ACCOUNT_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
TOKEN_PATH = f"{SERVICE_ACCOUNT_DIR}/token"
CA_PATH = f"{SERVICE_ACCOUNT_DIR}/ca.crt"
TARGET_REGISTRY = "oci.cdn.keiretsu.top"
MANIFEST_ACCEPT = (
    "application/vnd.oci.image.manifest.v1+json, "
    "application/vnd.oci.image.index.v1+json, "
    "application/vnd.docker.distribution.manifest.v2+json, "
    "application/vnd.docker.distribution.manifest.list.v2+json"
)


@dataclass(frozen=True)
class ImageReference:
    original: str
    registry: str
    repository: str
    reference: str

    @property
    def manifest_url(self) -> str:
        repository = quote(self.repository, safe="/._-")
        reference = quote(self.reference, safe="._:@+-")
        return f"https://{self.registry}/v2/{repository}/manifests/{reference}"


@dataclass(frozen=True)
class WorkloadReference:
    image: str
    namespace: str
    pod: str
    container: str
    container_type: str
    owner_kind: str
    owner_name: str


@dataclass(frozen=True)
class PodVolumeReference:
    namespace: str
    pvc: str
    volume: str
    labels: dict[str, str]
    annotations: dict[str, str]


@dataclass(frozen=True)
class PVCSelectionGap:
    namespace: str
    pvc: str
    storage_class: str
    reason: str


@dataclass(frozen=True)
class PVCStructuralExclusion:
    namespace: str
    pvc: str
    storage_class: str
    reason: str


def normalize_image(image: str) -> ImageReference:
    """Resolve Docker's implicit registry, namespace, and latest tag."""

    if not image or image != image.strip():
        raise ValueError(f"invalid image reference {image!r}")

    if "@" in image:
        name, reference = image.rsplit("@", 1)
    else:
        slash = image.rfind("/")
        colon = image.rfind(":")
        if colon > slash:
            name, reference = image[:colon], image[colon + 1 :]
        else:
            name, reference = image, "latest"

    parts = name.split("/")
    first = parts[0]
    if len(parts) == 1 or ("." not in first and ":" not in first and first != "localhost"):
        registry = "docker.io"
        repository_parts = parts
    else:
        registry = first
        repository_parts = parts[1:]

    if registry == "docker.io" and len(repository_parts) == 1:
        repository_parts.insert(0, "library")
    repository = "/".join(repository_parts)
    if not repository or not reference:
        raise ValueError(f"invalid image reference {image!r}")
    return ImageReference(image, registry, repository, reference)


def label_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def metric_labels(labels: dict[str, str]) -> str:
    return ",".join(
        f'{key}="{label_escape(value)}"' for key, value in sorted(labels.items())
    )


def read_token() -> str:
    with open(TOKEN_PATH, encoding="utf-8") as token_file:
        return token_file.read().strip()


def kubernetes_tls_context() -> ssl.SSLContext:
    """Trust the cluster CA for the Kubernetes API server only."""

    return ssl.create_default_context(cafile=CA_PATH)


def registry_tls_context() -> ssl.SSLContext:
    """Trust public/system CAs for the external registry HTTPS endpoint.

    The mounted ServiceAccount CA authenticates the Kubernetes API server; it
    is not a trust bundle for arbitrary HTTPS destinations such as Zot.
    """

    # The ServiceAccount CA is for kubernetes.default.svc, not arbitrary HTTPS.
    return ssl.create_default_context()


def api_get(path: str, token: str, context: ssl.SSLContext) -> dict[str, Any]:
    request = Request(
        API_BASE + path,
        headers={"Accept": "application/json", "Authorization": f"Bearer {token}"},
    )
    with urlopen(request, context=context, timeout=10) as response:
        payload = json.load(response)
    if not isinstance(payload, dict):
        raise RuntimeError("Kubernetes API returned a non-object response")
    return payload


def list_resources(
    path: str,
    token: str,
    context: ssl.SSLContext,
    query: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    """List every object at a Kubernetes collection endpoint."""

    resources: list[dict[str, Any]] = []
    continue_token = ""
    while True:
        params = {"limit": "500", **(query or {})}
        if continue_token:
            params["continue"] = continue_token
        payload = api_get(f"{path}?{urlencode(params)}", token, context)
        items = payload.get("items", [])
        if not isinstance(items, list):
            raise RuntimeError(f"Kubernetes API returned non-list items for {path}")
        resources.extend(item for item in items if isinstance(item, dict))
        metadata = payload.get("metadata", {})
        if not isinstance(metadata, dict):
            raise RuntimeError(f"Kubernetes API returned invalid metadata for {path}")
        continue_token = metadata.get("continue", "")
        if not isinstance(continue_token, str) or not continue_token:
            return resources


def running_pods(token: str, context: ssl.SSLContext) -> list[dict[str, Any]]:
    return list_resources(
        API_PATH,
        token,
        context,
        {"fieldSelector": "status.phase=Running"},
    )


def object_labels(obj: dict[str, Any]) -> dict[str, str]:
    metadata = obj.get("metadata", {})
    if not isinstance(metadata, dict):
        return {}
    labels = metadata.get("labels", {})
    if not isinstance(labels, dict):
        return {}
    return {str(key): str(value) for key, value in labels.items()}


def object_annotations(obj: dict[str, Any]) -> dict[str, str]:
    metadata = obj.get("metadata", {})
    if not isinstance(metadata, dict):
        return {}
    annotations = metadata.get("annotations", {})
    if not isinstance(annotations, dict):
        return {}
    return {str(key): str(value) for key, value in annotations.items()}


def object_namespace(obj: dict[str, Any]) -> str:
    metadata = obj.get("metadata", {})
    return str(metadata.get("namespace", "")) if isinstance(metadata, dict) else ""


def object_name(obj: dict[str, Any]) -> str:
    metadata = obj.get("metadata", {})
    return str(metadata.get("name", "")) if isinstance(metadata, dict) else ""


def controller_owner(metadata: dict[str, Any]) -> tuple[str, str]:
    owners = metadata.get("ownerReferences", [])
    if not isinstance(owners, list):
        return "", ""
    owner = next((item for item in owners if item.get("controller")), None)
    if owner is None and owners:
        owner = owners[0]
    if not isinstance(owner, dict):
        return "", ""
    return str(owner.get("kind", "")), str(owner.get("name", ""))


def workload_references(pods: list[dict[str, Any]]) -> list[WorkloadReference]:
    references: list[WorkloadReference] = []
    for pod in pods:
        metadata = pod.get("metadata", {})
        if not isinstance(metadata, dict):
            continue
        namespace = str(metadata.get("namespace", ""))
        pod_name = str(metadata.get("name", ""))
        owner_kind, owner_name = controller_owner(metadata)
        spec = pod.get("spec", {})
        if not isinstance(spec, dict):
            continue
        for container_type, field in (
            ("init", "initContainers"),
            ("regular", "containers"),
            ("ephemeral", "ephemeralContainers"),
        ):
            containers = spec.get(field, [])
            if not isinstance(containers, list):
                continue
            for container in containers:
                if not isinstance(container, dict) or not container.get("image"):
                    continue
                references.append(
                    WorkloadReference(
                        image=str(container["image"]),
                        namespace=namespace,
                        pod=pod_name,
                        container=str(container.get("name", "")),
                        container_type=container_type,
                        owner_kind=owner_kind,
                        owner_name=owner_name,
                    )
                )
    return references


def pvc_volume_references(
    pods: list[dict[str, Any]],
) -> dict[tuple[str, str], list[PodVolumeReference]]:
    """Index Pod PVC volumes by namespace and claim name.

    Keep completed Pod objects here. Velero selects Kubernetes objects from
    the API, and a completed Job Pod can still be the only object describing
    the PVC volume and its backup annotations (for example, a one-shot
    workload). The image probe separately remains limited to running Pods.
    """

    references: dict[tuple[str, str], list[PodVolumeReference]] = {}
    for pod in pods:
        namespace = object_namespace(pod)
        spec = pod.get("spec", {})
        if not namespace or not isinstance(spec, dict):
            continue
        volumes = spec.get("volumes", [])
        if not isinstance(volumes, list):
            continue
        labels = object_labels(pod)
        annotations = object_annotations(pod)
        for volume in volumes:
            if not isinstance(volume, dict):
                continue
            claim = volume.get("persistentVolumeClaim", {})
            if not isinstance(claim, dict):
                continue
            pvc = claim.get("claimName")
            volume_name = volume.get("name")
            if not isinstance(pvc, str) or not pvc or not isinstance(volume_name, str):
                continue
            reference = PodVolumeReference(
                namespace=namespace,
                pvc=pvc,
                volume=volume_name,
                labels=labels,
                annotations=annotations,
            )
            references.setdefault((namespace, pvc), []).append(reference)
    return references


def selector_matches(labels: dict[str, str], selector: Any) -> bool:
    """Evaluate the Kubernetes LabelSelector shape used by Velero."""

    if not isinstance(selector, dict):
        return True
    match_labels = selector.get("matchLabels", {})
    if isinstance(match_labels, dict):
        for key, value in match_labels.items():
            if labels.get(str(key)) != str(value):
                return False

    expressions = selector.get("matchExpressions", [])
    if not isinstance(expressions, list):
        return False
    for expression in expressions:
        if not isinstance(expression, dict):
            return False
        key = str(expression.get("key", ""))
        operator = expression.get("operator")
        values = expression.get("values", [])
        if not key or not isinstance(values, list):
            values = []
        value = labels.get(key)
        if operator == "In" and (value is None or value not in {str(item) for item in values}):
            return False
        if operator == "NotIn" and value is not None and value in {
            str(item) for item in values
        }:
            return False
        if operator == "Exists" and value is None:
            return False
        if operator == "DoesNotExist" and value is not None:
            return False
        if operator not in ("In", "NotIn", "Exists", "DoesNotExist"):
            return False
    return True


def resource_selector_matches(resources: Any, resource: str) -> bool:
    if not resources:
        return False
    if not isinstance(resources, list):
        return False
    for item in resources:
        name = str(item).lower().split("/", 1)[-1]
        if name in ("*", resource.lower()):
            return True
    return False


def schedule_selects(
    schedule: dict[str, Any],
    namespace: str,
    labels: dict[str, str],
    resource: str,
) -> bool:
    """Apply a live Velero Schedule's namespace/resource/label selector."""

    spec = schedule.get("spec", {})
    if not isinstance(spec, dict):
        return False
    template = spec.get("template", {})
    if not isinstance(template, dict):
        return False
    if spec.get("paused") is True:
        return False

    included_namespaces = template.get("includedNamespaces", [])
    if included_namespaces and "*" not in included_namespaces:
        if not isinstance(included_namespaces, list) or namespace not in included_namespaces:
            return False
    excluded_namespaces = template.get("excludedNamespaces", [])
    if isinstance(excluded_namespaces, list) and (
        "*" in excluded_namespaces or namespace in excluded_namespaces
    ):
        return False
    included_resources = template.get("includedResources")
    if included_resources and not resource_selector_matches(included_resources, resource):
        return False
    if resource_selector_matches(template.get("excludedResources"), resource):
        return False
    return selector_matches(labels, template.get("labelSelector"))


def annotation_names(annotations: dict[str, str], key: str) -> set[str]:
    value = annotations.get(key, "")
    if not value:
        return set()
    return {item.strip() for item in value.split(",") if item.strip()}


def schedule_selects_volume(schedule: dict[str, Any], mount: PodVolumeReference) -> bool:
    template = schedule.get("spec", {}).get("template", {})
    if not isinstance(template, dict):
        return False
    if mount.volume in annotation_names(
        mount.annotations, "backup.velero.io/backup-volumes-excludes"
    ):
        return False
    if template.get("defaultVolumesToFsBackup") is True:
        return True
    return mount.volume in annotation_names(
        mount.annotations, "backup.velero.io/backup-volumes"
    )


def structural_exclusion_reason(
    pvc: dict[str, Any], pv: dict[str, Any] | None,
) -> str | None:
    spec = pvc.get("spec", {})
    if not isinstance(spec, dict):
        spec = {}
    storage_class = str(spec.get("storageClassName", ""))
    if storage_class == "local-path":
        if isinstance(pv, dict):
            pv_spec = pv.get("spec", {})
            if isinstance(pv_spec, dict) and pv_spec.get("hostPath") is not None:
                return "hostpath"
        return "local_path"
    if isinstance(pv, dict):
        pv_spec = pv.get("spec", {})
        if isinstance(pv_spec, dict) and pv_spec.get("hostPath") is not None:
            return "hostpath"
    return None


def evaluate_pvc_selection(
    pvcs: list[dict[str, Any]],
    pvs: list[dict[str, Any]],
    pods: list[dict[str, Any]],
    schedules: list[dict[str, Any]],
) -> tuple[list[PVCSelectionGap], list[PVCStructuralExclusion]]:
    """Evaluate effective Velero PVC data selection from current API objects.

    A Schedule can select a PVC object while selecting no Pod volume data. That
    is intentionally a separate ``no_volume_selection`` result: the successful
    Backup in that case is still a metadata-only false positive.
    """

    pv_by_name = {
        object_name(pv): pv for pv in pvs if object_name(pv)
    }
    mounted = pvc_volume_references(pods)
    gaps: list[PVCSelectionGap] = []
    structural: list[PVCStructuralExclusion] = []

    for pvc in pvcs:
        namespace = object_namespace(pvc)
        name = object_name(pvc)
        status = pvc.get("status", {})
        if not namespace or not name or (
            isinstance(status, dict)
            and status.get("phase") not in (None, "Bound")
        ):
            continue
        spec = pvc.get("spec", {})
        if not isinstance(spec, dict):
            spec = {}
        storage_class = str(spec.get("storageClassName", ""))
        pv = pv_by_name.get(str(spec.get("volumeName", "")))

        structural_reason = structural_exclusion_reason(pvc, pv)
        if structural_reason is not None:
            structural.append(
                PVCStructuralExclusion(namespace, name, storage_class, structural_reason)
            )
            continue

        annotations = object_annotations(pvc)
        pvc_labels = object_labels(pvc)
        if (
            annotations.get("velero.io/exclude-from-backup", "").lower() == "true"
            or pvc_labels.get("velero.io/exclude-from-backup", "").lower() == "true"
        ):
            continue

        mounts = mounted.get((namespace, name), [])
        matching_schedules: set[str] = set()
        data_schedules: set[str] = set()
        for schedule in schedules:
            schedule_name = object_name(schedule)
            if not schedule_name:
                continue
            pvc_selected = schedule_selects(
                schedule, namespace, pvc_labels, "persistentvolumeclaims"
            )
            pod_selected = False
            for mount in mounts:
                if not schedule_selects(schedule, mount.namespace, mount.labels, "pods"):
                    continue
                pod_selected = True
                if schedule_selects_volume(schedule, mount):
                    data_schedules.add(schedule_name)
            if pvc_selected or pod_selected:
                matching_schedules.add(schedule_name)

        if not matching_schedules:
            gaps.append(PVCSelectionGap(namespace, name, storage_class, "no_schedule"))
        elif not data_schedules:
            gaps.append(
                PVCSelectionGap(namespace, name, storage_class, "no_volume_selection")
            )

    gaps.sort(key=lambda item: (item.namespace, item.pvc, item.reason))
    structural.sort(key=lambda item: (item.namespace, item.pvc, item.reason))
    return gaps, structural


def classify_response(response_code: int) -> str:
    if response_code == 404:
        return "missing"
    if 200 <= response_code < 400:
        return "present"
    return "unknown"


def manifest_request(
    image: ImageReference,
    context: ssl.SSLContext,
    method: str,
) -> str:
    headers = {"Accept": MANIFEST_ACCEPT, "User-Agent": "running-workload-image-probe/1"}
    if method == "GET":
        headers["Range"] = "bytes=0-0"
    request = Request(image.manifest_url, headers=headers, method=method)
    with urlopen(request, context=context, timeout=10) as response:
        if method == "GET":
            response.read(1)
        return classify_response(response.status)


def probe_manifest(image: ImageReference, context: ssl.SSLContext) -> str:
    try:
        return manifest_request(image, context, "HEAD")
    except HTTPError as error:
        if error.code == 404:
            return "missing"
        if error.code not in (405, 501):
            return "unknown"
    except (OSError, URLError, TimeoutError):
        return "unknown"

    # A small number of registries do not implement HEAD.  GET is still a
    # manifest existence check; the response body is discarded immediately.
    try:
        return manifest_request(image, context, "GET")
    except HTTPError as error:
        return "missing" if error.code == 404 else "unknown"
    except (OSError, URLError, TimeoutError):
        return "unknown"


def probe_images(
    images: set[str], context: ssl.SSLContext, workers: int
) -> dict[str, tuple[str, str]]:
    """Probe only images served by the registry this detector owns."""

    results: dict[str, tuple[str, str]] = {}
    normalized: dict[str, ImageReference] = {}
    for image in images:
        try:
            parsed = normalize_image(image)
        except ValueError:
            if image.startswith(f"{TARGET_REGISTRY}/"):
                results[image] = ("unknown", TARGET_REGISTRY)
            continue
        if parsed.registry != TARGET_REGISTRY:
            continue
        normalized[image] = parsed

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(probe_manifest, parsed, context): image
            for image, parsed in normalized.items()
        }
        for future in as_completed(futures):
            image = futures[future]
            parsed = normalized[image]
            try:
                status = future.result()
            except Exception:
                status = "unknown"
            results[image] = (status, parsed.registry)
    return results


def text_metric(name: str, help_text: str, metric_type: str) -> list[str]:
    return [
        f"# HELP {name} {help_text}",
        f"# TYPE {name} {metric_type}",
    ]


def render_selection_metrics(
    gaps: list[PVCSelectionGap],
    structural_exclusions: list[PVCStructuralExclusion],
    scan_success: bool,
    scan_timestamp: float,
    last_success_timestamp: float,
    cluster: str | None = None,
) -> str:
    """Render the current PVC-selection state collected by this probe."""

    cluster = os.environ.get("CLUSTER_NAME", "") if cluster is None else cluster
    lines: list[str] = []
    gap_name = "velero_pvc_backup_selection_gap"
    lines.extend(
        text_metric(
            gap_name,
            "Current PVCs with no effective Velero filesystem backup selection.",
            "gauge",
        )
    )
    structural_name = "velero_pvc_backup_structural_exclusion"
    lines.extend(
        text_metric(
            structural_name,
            "Current PVCs structurally excluded from Velero filesystem backup.",
            "gauge",
        )
    )
    if scan_success:
        for gap in gaps:
            labels = metric_labels(
                {
                    "cluster": cluster,
                    "namespace": gap.namespace,
                    "pvc": gap.pvc,
                    "reason": gap.reason,
                    "storage_class": gap.storage_class,
                }
            )
            lines.append(f"{gap_name}{{{labels}}} 1")
        for exclusion in structural_exclusions:
            labels = metric_labels(
                {
                    "cluster": cluster,
                    "namespace": exclusion.namespace,
                    "pvc": exclusion.pvc,
                    "reason": exclusion.reason,
                    "storage_class": exclusion.storage_class,
                }
            )
            lines.append(f"{structural_name}{{{labels}}} 1")

    scan_name = "velero_pvc_backup_selection_scan_success"
    lines.extend(
        text_metric(
            scan_name,
            "Whether the last PVC Velero-selection scan succeeded.",
            "gauge",
        )
    )
    lines.append(f"{scan_name}{{cluster=\"{label_escape(cluster)}\"}} {int(scan_success)}")
    timestamp_name = "velero_pvc_backup_selection_last_scan_timestamp_seconds"
    lines.extend(
        text_metric(
            timestamp_name,
            "Unix timestamp of the last PVC selection scan.",
            "gauge",
        )
    )
    lines.append(
        f"{timestamp_name}{{cluster=\"{label_escape(cluster)}\"}} {scan_timestamp:.3f}"
    )
    success_name = "velero_pvc_backup_selection_last_success_timestamp_seconds"
    lines.extend(
        text_metric(
            success_name,
            "Unix timestamp of the last successful PVC selection scan.",
            "gauge",
        )
    )
    lines.append(
        f"{success_name}{{cluster=\"{label_escape(cluster)}\"}} "
        f"{last_success_timestamp:.3f}"
    )
    return "\n".join(lines) + "\n"


def render_metrics(
    references: list[WorkloadReference],
    statuses: dict[str, tuple[str, str]],
    scan_success: bool,
    scan_timestamp: float,
    scan_duration: float,
    last_success_timestamp: float,
    selection_gaps: list[PVCSelectionGap] | None = None,
    structural_exclusions: list[PVCStructuralExclusion] | None = None,
    selection_scan_success: bool = False,
    selection_scan_timestamp: float = 0.0,
    selection_last_success_timestamp: float = 0.0,
    selection_cluster: str | None = None,
) -> str:
    lines: list[str] = []
    status_name = "running_workload_image_registry_probe_status"
    lines.extend(text_metric(status_name, "Current OCI manifest probe result.", "gauge"))
    count_name = "running_workload_image_registry_probe_references"
    lines.extend(
        text_metric(
            count_name,
            "Number of running pod container references for an image.",
            "gauge",
        )
    )
    info_name = "running_workload_image_registry_probe_reference_info"
    lines.extend(
        text_metric(
            info_name,
            "Running pod container reference included in the image probe.",
            "gauge",
        )
    )

    monitored_references = [
        reference for reference in references if reference.image in statuses
    ]
    by_image: dict[str, list[WorkloadReference]] = {}
    for reference in monitored_references:
        by_image.setdefault(reference.image, []).append(reference)

    if scan_success:
        for image, (status, registry) in sorted(statuses.items()):
            labels = metric_labels(
                {"image": image, "registry": registry, "status": status}
            )
            lines.append(f"{status_name}{{{labels}}} 1")
            count_labels = metric_labels(
                {"image": image, "registry": registry, "status": status}
            )
            lines.append(
                f"{count_name}{{{count_labels}}} {len(by_image.get(image, []))}"
            )

        for reference in monitored_references:
            labels = metric_labels(
                {
                    "container": reference.container,
                    "container_type": reference.container_type,
                    "image": reference.image,
                    "namespace": reference.namespace,
                    "owner_kind": reference.owner_kind,
                    "owner_name": reference.owner_name,
                    "pod": reference.pod,
                }
            )
            lines.append(f"{info_name}{{{labels}}} 1")

    scan_name = "running_workload_image_registry_probe_scan_success"
    lines.extend(text_metric(scan_name, "Whether the last pod/image scan succeeded.", "gauge"))
    lines.append(f"{scan_name} {int(scan_success)}")
    timestamp_name = "running_workload_image_registry_probe_last_scan_timestamp_seconds"
    lines.extend(text_metric(timestamp_name, "Unix timestamp of the last scan.", "gauge"))
    lines.append(f"{timestamp_name} {scan_timestamp:.3f}")
    success_name = (
        "running_workload_image_registry_probe_last_success_timestamp_seconds"
    )
    lines.extend(text_metric(success_name, "Unix timestamp of the last successful scan.", "gauge"))
    lines.append(f"{success_name} {last_success_timestamp:.3f}")
    duration_name = "running_workload_image_registry_probe_scan_duration_seconds"
    lines.extend(text_metric(duration_name, "Duration of the last scan.", "gauge"))
    lines.append(f"{duration_name} {scan_duration:.3f}")
    images_name = "running_workload_image_registry_probe_images"
    lines.extend(text_metric(images_name, "Number of unique images in the last scan.", "gauge"))
    lines.append(f"{images_name} {len(statuses) if scan_success else 0}")
    image_metrics = "\n".join(lines) + "\n"
    selection_metrics = render_selection_metrics(
        selection_gaps or [],
        structural_exclusions or [],
        selection_scan_success,
        selection_scan_timestamp,
        selection_last_success_timestamp,
        selection_cluster,
    )
    return image_metrics + selection_metrics


class MetricsState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.value = render_metrics([], {}, False, 0.0, 0.0, 0.0)

    def replace(self, value: str) -> None:
        with self.lock:
            self.value = value

    def get(self) -> str:
        with self.lock:
            return self.value


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    state: MetricsState

    def do_GET(self) -> None:  # noqa: N802 - standard library handler API
        if self.path == "/healthz":
            payload = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path != "/metrics":
            self.send_error(404)
            return
        payload = self.state.get().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args: object) -> None:
        return


def scan_once(state: MetricsState, workers: int) -> None:
    started = time.time()
    try:
        token = read_token()
        api_context = kubernetes_tls_context()
        # Image liveness is intentionally running-Pod-only. PVC selection must
        # inspect every Pod object because a completed Job can still be the
        # selected Pod/volume pair that Velero backs up.
        pods = list_resources(API_PATH, token, api_context)
        running = [
            pod
            for pod in pods
            if isinstance(pod.get("status"), dict)
            and pod["status"].get("phase") == "Running"
        ]
        references = workload_references(running)
        statuses = probe_images(
            {reference.image for reference in references},
            registry_tls_context(),
            workers,
        )
        pvcs = list_resources(PVC_API_PATH, token, api_context)
        pvs = list_resources(PV_API_PATH, token, api_context)
        schedules = list_resources(VELERO_SCHEDULE_API_PATH, token, api_context)
        selection_gaps, structural_exclusions = evaluate_pvc_selection(
            pvcs, pvs, pods, schedules
        )
        now = time.time()
        state.replace(
            render_metrics(
                references,
                statuses,
                True,
                now,
                now - started,
                now,
                selection_gaps,
                structural_exclusions,
                True,
                now,
                now,
            )
        )
    except Exception as error:
        print(f"monitoring probe scan failed: {error}", file=sys.stderr, flush=True)
        now = time.time()
        state.replace(render_metrics([], {}, False, now, now - started, 0.0))


def scan_loop(state: MetricsState, interval: float, workers: int) -> None:
    while True:
        scan_once(state, workers)
        time.sleep(interval)


def main() -> None:
    port = int(os.environ.get("METRICS_PORT", "9095"))
    interval = max(float(os.environ.get("SCAN_INTERVAL_SECONDS", "300")), 30.0)
    workers = max(1, min(int(os.environ.get("PROBE_WORKERS", "8")), 32))
    state = MetricsState()
    MetricsHandler.state = state
    threading.Thread(
        target=scan_loop,
        args=(state, interval, workers),
        daemon=True,
    ).start()
    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), MetricsHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
