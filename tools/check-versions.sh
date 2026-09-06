#!/usr/bin/env bash
# tools/check-versions.sh — assert that files which must move together do.
#
# Version invariants, mostly per cluster, so one cluster upgrading never implies
# anything about another:
#
# 1. talconfig vs the tuppr upgrade CRs (Talos/Kubernetes versions).
#    A mismatch means an upgrade touched one file but not the other. tuppr skips
#    nodes listed in status.completedNodes, so the drift stays dormant — until
#    any spec change bumps the CR's generation, which clears that list and makes
#    tuppr roll every node to whatever the CR says. If the CR is behind, that is
#    a downgrade.
#
# 2. CephCluster daemon image vs the rook-ceph toolbox image.
#    Both are the same quay.io/ceph/ceph tag and Renovate moves them in one
#    per-cluster PR. If only one moves, the toolbox runs client code from a
#    different Ceph release than the daemons it administers — which is exactly
#    the tool you reach for mid-upgrade to decide whether the cluster is healthy.
#
# 3. CephCluster daemon image vs what the deployed Rook operator will run.
#    Rook refuses any Ceph major absent from the supportedVersions list compiled
#    into the operator, and refuses non-stable releases, unless
#    allowUnsupported is true. It fails the version check before it populates
#    cluster info, so the operator never finishes initializing: no mon failover,
#    no OSD lifecycle, no reconcile of anything, and the CephFilesystem
#    controller respawns a detect-version job every ~10s forever. The daemons
#    are left untouched at their old release, so nothing looks broken until you
#    read the CephCluster status. Both inputs are in git, and Rook's supported
#    list is readable at the operator's own tag, so this is checkable here
#    rather than discovered in production. Ceph puts the release type in the
#    minor field (x.0.z development, x.1.z release candidate, x.2.z stable), so
#    an RC has no prerelease suffix for Renovate to filter on: v21.1.0 shipped
#    to both clusters as a routine major bump.
#
# 4. Semver-coupled application artifacts. Renovate groups related packages for
#    review, while this script enforces the actual invariant across distinct
#    files: runtime, charts, release manifests, schemas, dashboards, and CRDs
#    must resolve to the same normalized upstream version.
#
# Deliberate mismatches: put '# version-sync: ignore' in the tuppr, toolbox, or
# CephCluster file.
#
# Usage:
#   tools/check-versions.sh
set -euo pipefail
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Locate pyyaml in the user nix profile if the system python doesn't have it
if ! python3 -c "import yaml" 2>/dev/null; then
  _yaml_site=$(find /workspace/.local/share/nix/root/nix/store -maxdepth 1 -name "*pyyaml*" -not -name "*.drv" -type d 2>/dev/null | head -1)
  if [ -n "$_yaml_site" ]; then
    export PYTHONPATH="${_yaml_site}/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
  fi
fi

python3 - <<'PY'
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

import yaml


def fetch_url(url, timeout=20, attempts=3, read=True):
    # These fetches are the only part of this script that touches the network,
    # so a single upstream reset would otherwise fail the whole version check
    # and hide every real invariant behind a red run. urllib.error.URLError is
    # an OSError, so one except clause covers connection resets and timeouts;
    # the original exception is re-raised on the last attempt so callers keep
    # their existing messages. Pass read=False for reachability-only checks:
    # some asserted assets are binary (Kometa ships a fonts.zip) and decoding
    # them would fail for a reason that has nothing to do with availability.
    delay = 1
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                if resp.status != 200:
                    raise OSError(f"HTTP {resp.status}")
                return resp.read().decode() if read else None
        except OSError:
            if attempt == attempts:
                raise
            time.sleep(delay)
            delay *= 2


CLUSTERS = ["ottawa", "robbinsdale", "stpetersburg"]
# Rook-Ceph runs on Ottawa and Robbinsdale only; St. Petersburg has no cluster.
CEPH_CLUSTERS = ["ottawa", "robbinsdale"]
MARKER = "# version-sync: ignore"
PAIRS = [
    ("talosVersion", "talos-upgrade.yaml", "talos"),
    ("kubernetesVersion", "kubernetes-upgrade.yaml", "kubernetes"),
]
CEPH_IMAGE = "quay.io/ceph/ceph:"
ROOK_SRC = (
    "https://raw.githubusercontent.com/rook/rook/{tag}"
    "/pkg/operator/ceph/version/version.go"
)
PIRAEUS_INDEX = "https://piraeus.io/helm-charts/index.yaml"
# Ceph release type lives in the minor field; x.2.z is the stable line.
CEPH_STABLE_MINOR = 2

failures = []
skipped = []
rook_verified = []

for cluster in CLUSTERS:
    talconfig = pathlib.Path(f"clusters/talos-{cluster}/bootstrap/talos/talconfig.yaml")
    declared = yaml.safe_load(talconfig.read_text())

    for talkey, filename, speckey in PAIRS:
        crfile = pathlib.Path(
            f"kubernetes/apps/base/tuppr/tuppr-config-{cluster}/config/{filename}"
        )
        raw = crfile.read_text()

        if MARKER in raw:
            skipped.append(f"{cluster}/{filename}")
            continue

        want = declared[talkey]
        got = yaml.safe_load(raw)["spec"][speckey]["version"]
        if want != got:
            failures.append(
                f"  {cluster}: {talconfig}\n"
                f"    {talkey}: {want}\n"
                f"  vs {crfile}\n"
                f"    spec.{speckey}.version: {got}"
            )

for cluster in CEPH_CLUSTERS:
    base = pathlib.Path(f"kubernetes/apps/base/rook-ceph/rook-ceph-{cluster}/config")
    clusterfile = base / "cluster.yaml"
    toolboxfile = base / "toolbox.yaml"
    raw = toolboxfile.read_text()

    if MARKER in raw:
        skipped.append(f"{cluster}/toolbox.yaml")
        continue

    want = yaml.safe_load(clusterfile.read_text())["spec"]["cephVersion"]["image"]
    containers = yaml.safe_load(raw)["spec"]["template"]["spec"]["containers"]
    images = [c["image"] for c in containers if c["image"].startswith(CEPH_IMAGE)]

    if not images:
        failures.append(
            f"  {cluster}: {toolboxfile}\n"
            f"    no container running {CEPH_IMAGE}* — cannot verify against\n"
            f"  {clusterfile}\n"
            f"    spec.cephVersion.image: {want}"
        )
        continue

    for got in sorted(set(images)):
        if want != got:
            failures.append(
                f"  {cluster}: {clusterfile}\n"
                f"    spec.cephVersion.image: {want}\n"
                f"  vs {toolboxfile}\n"
                f"    container image: {got}"
            )

for cluster in CEPH_CLUSTERS:
    base = pathlib.Path(f"kubernetes/apps/base/rook-ceph/rook-ceph-{cluster}")
    clusterfile = base / "config" / "cluster.yaml"
    hrfile = base / "app" / "helmrelease.yaml"
    raw = clusterfile.read_text()

    if MARKER in raw:
        skipped.append(f"{cluster}/cluster.yaml")
        continue

    cephspec = yaml.safe_load(raw)["spec"]["cephVersion"]
    image = cephspec["image"]

    if cephspec.get("allowUnsupported"):
        skipped.append(f"{cluster}/cluster.yaml (allowUnsupported: true)")
        continue

    parsed = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", image.split(":", 1)[-1])
    if not parsed:
        failures.append(
            f"  {cluster}: {clusterfile}\n"
            f"    spec.cephVersion.image: {image}\n"
            f"    tag is not a vX.Y.Z release — cannot check it against Rook"
        )
        continue
    major, minor = int(parsed[1]), int(parsed[2])

    if minor != CEPH_STABLE_MINOR:
        kind = "development build" if minor == 0 else "release candidate"
        failures.append(
            f"  {cluster}: {clusterfile}\n"
            f"    spec.cephVersion.image: {image}\n"
            f"    {major}.{minor}.z is a Ceph {kind}, not a stable release.\n"
            f"    Stable Ceph is x.{CEPH_STABLE_MINOR}.z — see\n"
            f"    https://docs.ceph.com/en/latest/releases/general/"
        )
        continue

    rook_tag = yaml.safe_load(hrfile.read_text())["spec"]["chart"]["spec"]["version"]
    if not rook_tag.startswith("v"):
        rook_tag = f"v{rook_tag}"
    url = ROOK_SRC.format(tag=rook_tag)

    try:
        src = fetch_url(url)
    except (urllib.error.URLError, OSError) as err:
        note = f"{cluster}/cluster.yaml (could not read {url}: {err})"
        if os.environ.get("CI"):
            failures.append(f"  {note}")
        else:
            skipped.append(f"{note} — offline, Rook support NOT verified")
        continue

    majors = {
        name: int(num)
        for name, num in re.findall(r"(\w+)\s*=\s*CephVersion\{(\d+),", src)
    }
    listed = re.search(r"supportedVersions\s*=\s*\[\]CephVersion\{([^}]*)\}", src)
    supported = sorted(
        {majors[n] for n in (n.strip() for n in listed[1].split(",")) if n in majors}
    ) if listed else []

    if not supported:
        failures.append(f"  {cluster}: could not parse supportedVersions from {url}")
        continue

    if major in supported:
        rook_verified.append(cluster)
    else:
        failures.append(
            f"  {cluster}: {clusterfile}\n"
            f"    spec.cephVersion.image: {image}  (Ceph major {major})\n"
            f"  vs {hrfile}\n"
            f"    spec.chart.spec.version: {rook_tag}\n"
            f"    that Rook release supports Ceph majors {supported}\n"
            f"    Rook fails its version check before initializing and stops\n"
            f"    reconciling this cluster entirely. Upgrade Rook first."
        )

SEMVER = re.compile(r"^(?:mimir-)?v?(\d+\.\d+\.\d+)(?:-thick)?$")


def canonical(value):
    match = SEMVER.fullmatch(str(value))
    if not match:
        raise ValueError(f"unsupported version {value!r}")
    return match.group(1)


def docs(path):
    return [doc for doc in yaml.safe_load_all(path.read_text()) if doc]


def container_image(path, name, repository):
    image = None
    for doc in docs(path):
        containers = doc.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        match = next((c["image"] for c in containers if c.get("name") == name), None)
        if match:
            image = match
            break
    if image is None:
        raise ValueError(f"container {name!r} not found in {path}")
    prefix = f"{repository}:"
    if not image.startswith(prefix):
        raise ValueError(f"{image!r} is not from {repository}")
    return canonical(image[len(prefix):].split("@", 1)[0])


def chart_version(path):
    return canonical(yaml.safe_load(path.read_text())["spec"]["chart"]["spec"]["version"])


def url_versions(path, pattern, expected):
    values = []
    for doc in docs(path):
        # Vendored dashboards carry their immutable upstream URL as metadata
        # because Grafana Operator accepts exactly one content source per CR.
        url = (
            doc.get("spec", {}).get("url")
            or doc.get("metadata", {}).get("annotations", {}).get(
                "monitoring.keiretsu.top/source-url"
            )
        )
        if not url:
            continue
        match = re.fullmatch(pattern, url)
        if match:
            if os.environ.get("CI"):
                try:
                    fetch_url(url, read=False)
                except (urllib.error.URLError, OSError, ValueError) as err:
                    raise ValueError(f"unavailable asset {url}: {err}") from err
            values.append(canonical(match.group("version")))
    if len(values) != expected:
        raise ValueError(f"expected {expected} matching URLs, found {len(values)}")
    return values


def require_equal(group, artifacts):
    try:
        values = [(label, getter()) for label, getter in artifacts]
    except (KeyError, StopIteration, TypeError, ValueError, yaml.YAMLError) as err:
        failures.append(f"  {group}: cannot extract all versions: {err}")
        return
    if len({value for _, value in values}) != 1:
        failures.append(
            f"  {group}: coupled artifacts differ\n"
            + "\n".join(f"    {label}: {value}" for label, value in values)
        )


mimir_dashboards = pathlib.Path(
    "kubernetes/apps/base/monitoring/grafana/dashboards/mimir/dashboards.yaml"
)
require_equal("Grafana Mimir", [
    ("mimirtool-ottawa", lambda: container_image(
        pathlib.Path("kubernetes/apps/base/mimir/mimir-ottawa/loader-job.yaml"),
        "rules-ottawa", "docker.io/grafana/mimirtool")),
    ("mimirtool-robbinsdale", lambda: container_image(
        pathlib.Path("kubernetes/apps/base/mimir/mimir-ottawa/loader-job.yaml"),
        "rules-robbinsdale", "docker.io/grafana/mimirtool")),
    ("mimirtool-stpetersburg", lambda: container_image(
        pathlib.Path("kubernetes/apps/base/mimir/mimir-ottawa/loader-job.yaml"),
        "rules-stpetersburg", "docker.io/grafana/mimirtool")),
    *[(f"dashboard-{index}", lambda value=value: value) for index, value in enumerate(
        url_versions(
            mimir_dashboards,
            r"https://raw\.githubusercontent\.com/grafana/mimir/(?P<version>mimir-\d+\.\d+\.\d+)/operations/mimir-mixin-compiled/dashboards/[^/\s]+\.json",
            7,
        ), 1
    )],
])

kromgo_config = pathlib.Path("kubernetes/apps/base/monitoring/kromgo/configmap.yaml")
require_equal("Kromgo", [
    ("runtime", lambda: container_image(
        pathlib.Path("kubernetes/apps/base/monitoring/kromgo/deployment.yaml"),
        "kromgo", "ghcr.io/home-operations/kromgo")),
    ("schema", lambda: canonical(re.search(
        r"home-operations/kromgo/([^/]+)/config\.schema\.json",
        kromgo_config.read_text(),
    ).group(1))),
])

require_equal("Open Cluster Management", [
    ("cluster-manager", lambda: chart_version(pathlib.Path(
        "kubernetes/apps/base/open-cluster-management/ocm-ottawa/helmrelease.yaml"))),
    ("klusterlet", lambda: chart_version(pathlib.Path(
        "kubernetes/apps/base/open-cluster-management-agent/ocm-agent/app/helmrelease.yaml"))),
])

require_equal("Flux operator/instance", [
    ("operator", lambda: chart_version(pathlib.Path(
        "kubernetes/apps/base/flux-system/flux-system-common/flux-operator/app/helmrelease.yaml"))),
    ("instance", lambda: chart_version(pathlib.Path(
        "kubernetes/apps/base/flux-system/flux-system-common/flux-instance/app/helmrelease.yaml"))),
])

for cluster in CLUSTERS:
    base = pathlib.Path(f"kubernetes/apps/base/kube-system/cilium-{cluster}/app")
    kustomization = base / "kustomization.yaml"

    def multus_manifest(path=kustomization):
        resource = next(
            item for item in yaml.safe_load(path.read_text())["resources"]
            if "multus-daemonset-thick.yml" in item
        )
        return canonical(re.search(r"/multus-cni/(v\d+\.\d+\.\d+)/", resource).group(1))

    def multus_runtime(cluster=cluster, base=base, path=kustomization):
        if cluster == "robbinsdale":
            patch = yaml.safe_load(path.read_text())["patches"][0]["patch"]
            doc = yaml.safe_load(patch)
        else:
            doc = yaml.safe_load((base / "patch-multus.yaml").read_text())
        containers = doc["spec"]["template"]["spec"]["initContainers"]
        image = next(c["image"] for c in containers if c["name"] == "install-multus-binary")
        return canonical(image.split(":", 1)[1].split("@", 1)[0])

    require_equal(f"Multus {cluster}", [
        ("manifest", multus_manifest),
        ("runtime", multus_runtime),
    ])

envoy_base = pathlib.Path(
    "kubernetes/apps/base/envoy-gateway-system/envoy-gw-common/install"
)
envoy_urls = []
for filename in ("dashboard-gateway.yaml", "dashboard-proxy.yaml"):
    envoy_urls.extend(url_versions(
        envoy_base / filename,
        r"https://raw\.githubusercontent\.com/envoyproxy/gateway/(?P<version>v\d+\.\d+\.\d+)/charts/gateway-addons-helm/dashboards/[^/\s]+\.json",
        1,
    ))
require_equal("Envoy Gateway", [
    ("chart", lambda: chart_version(envoy_base / "helmrelease.yaml")),
    *[(f"dashboard-{index}", lambda value=value: value) for index, value in enumerate(envoy_urls, 1)],
])

teslamate_urls = []
teslamate_base = pathlib.Path(
    "kubernetes/apps/base/monitoring/grafana/dashboards/teslamate"
)
for filename, expected in (("dashboards.yaml", 19), ("internal-reports.yaml", 4)):
    teslamate_urls.extend(url_versions(
        teslamate_base / filename,
        r"https://raw\.githubusercontent\.com/teslamate-org/teslamate/(?P<version>v\d+\.\d+\.\d+)/grafana/dashboards/.+\.json",
        expected,
    ))
require_equal("TeslaMate", [
    ("runtime", lambda: container_image(
        pathlib.Path("kubernetes/apps/base/teslamate/teslamate/app/deployment.yaml"),
        "teslamate", "teslamate/teslamate")),
    *[(f"dashboard-{index}", lambda value=value: value) for index, value in enumerate(teslamate_urls, 1)],
])

csi_repo = pathlib.Path("clusters/common/flux/repositories/helm/csi-driver-smb.yaml")
csi_url = yaml.safe_load(csi_repo.read_text())["spec"]["url"].rstrip("/")
csi_charts = [
    ("ottawa-chart", lambda: chart_version(pathlib.Path(
        "kubernetes/apps/base/csi-driver-smb/csi-driver-smb-ottawa/app/helmrelease.yaml"))),
    ("robbinsdale-chart", lambda: chart_version(pathlib.Path(
        "kubernetes/apps/base/csi-driver-smb/csi-driver-smb-robbinsdale/app/helmrelease.yaml"))),
]
if csi_url == "https://kubernetes-csi.github.io/csi-driver-smb":
    # The upstream GitHub Pages repository is stable; chart versions are
    # pinned and updated in the HelmReleases below.
    require_equal("CSI SMB", csi_charts)
else:
    csi_release = re.search(
        r"csi-driver-smb/(v\d+\.\d+\.\d+)/charts$", csi_url
    )
    if not csi_release:
        failures.append(f"  CSI SMB: unsupported HelmRepository URL: {csi_url}")
    else:
        require_equal(
            "CSI SMB",
            [("repository", lambda: canonical(csi_release.group(1))), *csi_charts],
        )

for site in ("ottawa", "robbinsdale"):
    kometa = pathlib.Path(
        f"kubernetes/apps/base/media/media-{site}/kometa/cronjob.yaml"
    )
    match = re.search(
        r"https://raw\.githubusercontent\.com/Kometa-Team/Community-Configs/"
        r"v\d+\.\d+\.\d+/[^\s]+\.zip",
        kometa.read_text(),
    )
    if not match:
        failures.append(f"  Kometa {site}: versioned fonts archive URL not found")
    elif os.environ.get("CI"):
        try:
            fetch_url(match.group(0), read=False)
        except (urllib.error.URLError, OSError, ValueError) as err:
            failures.append(f"  Kometa {site}: unavailable asset {match.group(0)}: {err}")

snapshot_hr = pathlib.Path("kubernetes/apps/base/snapshot-controller/app/helmrelease.yaml")
snapshot_chart = yaml.safe_load(snapshot_hr.read_text())["spec"]["chart"]["spec"]["version"]
snapshot_expected = None
try:
    index = yaml.safe_load(fetch_url(PIRAEUS_INDEX))
    releases = index["entries"]["snapshot-controller"]
    release = next(item for item in releases if str(item["version"]) == str(snapshot_chart))
    snapshot_expected = canonical(release["appVersion"])
except (KeyError, StopIteration, TypeError, ValueError, yaml.YAMLError,
        urllib.error.URLError, OSError) as err:
    note = f"snapshot-controller chart {snapshot_chart}: cannot resolve appVersion from {PIRAEUS_INDEX}: {err}"
    if os.environ.get("CI"):
        failures.append(f"  {note}")
    else:
        skipped.append(f"{note} — offline, snapshot compatibility NOT verified")
snapshot_resources = yaml.safe_load(pathlib.Path(
    "kubernetes/apps/base/snapshot-controller/app/kustomization.yaml"
).read_text())["resources"]
snapshot_versions = [
    canonical(match.group(1))
    for resource in snapshot_resources
    if (match := re.search(r"external-snapshotter/(v\d+\.\d+\.\d+)/client/config/crd/", resource))
]
if snapshot_expected is not None and (
    len(snapshot_versions) != 3
    or any(value != snapshot_expected for value in snapshot_versions)
):
    failures.append(
        "  external-snapshotter: controller app marker and three CRD refs must match\n"
        f"    controller app: {snapshot_expected}\n"
        f"    CRDs: {snapshot_versions}"
    )

for entry in skipped:
    print(f"  skipped (marker): {entry}")

if failures:
    print("✗ version mismatch between files that must move together:\n", file=sys.stderr)
    print("\n\n".join(failures), file=sys.stderr)
    print(
        "\nFix both files, or add '# version-sync: ignore' to the tuppr, toolbox, "
        "or CephCluster file if the difference is intentional.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"✓ versions in sync: talos/kubernetes {' '.join(CLUSTERS)}"
    f" | ceph {' '.join(CEPH_CLUSTERS)}"
    f" | ceph supported by deployed rook"
    f" {' '.join(rook_verified) if rook_verified else '(none verified)'}"
)
PY
