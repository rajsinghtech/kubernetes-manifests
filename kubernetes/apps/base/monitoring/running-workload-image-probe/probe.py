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


def running_pods(token: str, context: ssl.SSLContext) -> list[dict[str, Any]]:
    pods: list[dict[str, Any]] = []
    continue_token = ""
    while True:
        query = {"fieldSelector": "status.phase=Running", "limit": "500"}
        if continue_token:
            query["continue"] = continue_token
        payload = api_get(f"{API_PATH}?{urlencode(query)}", token, context)
        items = payload.get("items", [])
        if not isinstance(items, list):
            raise RuntimeError("Kubernetes API returned a non-list items field")
        pods.extend(item for item in items if isinstance(item, dict))
        continue_token = payload.get("metadata", {}).get("continue", "")
        if not continue_token:
            return pods


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


def render_metrics(
    references: list[WorkloadReference],
    statuses: dict[str, tuple[str, str]],
    scan_success: bool,
    scan_timestamp: float,
    scan_duration: float,
    last_success_timestamp: float,
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
    return "\n".join(lines) + "\n"


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
        references = workload_references(running_pods(token, api_context))
        statuses = probe_images(
            {reference.image for reference in references},
            registry_tls_context(),
            workers,
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
            )
        )
    except Exception as error:
        print(f"image probe scan failed: {error}", file=sys.stderr, flush=True)
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
