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
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import yaml

ROOT = Path.cwd()
MIMIR = ROOT / "kubernetes/apps/base/mimir/mimir-ottawa"
RULES = MIMIR / "rules"
KUSTOMIZATION = MIMIR / "kustomization.yaml"
LOADER = MIMIR / "loader-job.yaml"
TEST_RUNNER = RULES / "tests" / "run.sh"
TEST_FIXTURES = RULES / "tests"
EXPECTED_GROUPS = (
    ROOT
    / "kubernetes/apps/base/monitoring/mimir-rule-completeness/expected-groups.tsv"
)
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


def git_output(*args):
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def changed_rule_names():
    """Return only production rule sources changed from the PR base.

    The repository intentionally has an older fixture backlog. This check is
    therefore diff-scoped: a new or modified source must join the exercised
    subset, while untouched legacy sources remain an explicit backlog.
    """
    configured_base = os.environ.get("FLATE_BASE")
    candidates = []
    if configured_base:
        candidates.append(configured_base)
        if "/" not in configured_base:
            candidates.append(f"origin/{configured_base}")
    candidates.extend(("origin/HEAD", "origin/main", "origin/master", "main"))
    merge_base = None
    for candidate in dict.fromkeys(candidates):
        merge_base = git_output("merge-base", "HEAD", candidate)
        if merge_base:
            break
    if merge_base is None:
        fail(
            "cannot determine the Mimir rule diff base; set FLATE_BASE to a "
            "branch or commit available to git"
        )
        return set()

    changed = git_output(
        "diff",
        "--name-only",
        "--diff-filter=AMR",
        merge_base,
        "HEAD",
        "--",
        str(RULES.relative_to(ROOT)),
    )
    if changed is None:
        fail("cannot inspect the Mimir rule diff with git")
        return set()

    rules_relative = RULES.relative_to(ROOT)
    return {
        path.stem
        for raw_path in changed.splitlines()
        if (path := Path(raw_path)).parent == rules_relative
        and path.suffix in {".yaml", ".yml"}
    }


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

changed_rules = changed_rule_names()


def render_mimir():
    # The source-level checks above protect the intended wiring. Render it too:
    # a malformed nameReference can otherwise leave a fixed-name Job in the
    # output while every source file still looks plausible. This is deliberately
    # a client-side check; the live immutable-Job case is covered by the
    # server-side dry-run required before deployment.
    if shutil.which("kustomize"):
        command = ["kustomize", "build", str(MIMIR)]
    elif shutil.which("kubectl"):
        command = ["kubectl", "kustomize", str(MIMIR)]
    else:
        fail("Mimir rule load-path check needs kustomize or kubectl to render the loader")
        return []
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"Mimir loader render failed: {error}")
        return []
    if result.returncode != 0:
        detail = result.stderr.strip().splitlines()[-1:] or ["unknown renderer error"]
        fail(f"Mimir loader render failed ({result.returncode}): {detail[0]}")
        return []
    try:
        return [document for document in yaml.safe_load_all(result.stdout) if document]
    except yaml.YAMLError as error:
        fail(f"Mimir loader render produced invalid YAML: {error}")
        return []


rendered = render_mimir()
rendered_rule_maps = [
    document
    for document in rendered
    if isinstance(document, dict)
    and document.get("kind") == "ConfigMap"
    and str(document.get("metadata", {}).get("name", "")).startswith("mimir-rules-")
]
rendered_loader_jobs = [
    document
    for document in rendered
    if isinstance(document, dict)
    and document.get("kind") == "Job"
    and str(document.get("metadata", {}).get("name", "")).startswith("mimir-rules-")
]
if len(rendered_rule_maps) != 1:
    fail(
        "Mimir render must contain exactly one content-hashed mimir-rules "
        f"ConfigMap, found {len(rendered_rule_maps)}"
    )
if len(rendered_loader_jobs) != 1:
    fail(
        "Mimir render must contain exactly one content-hashed rules loader "
        f"Job, found {len(rendered_loader_jobs)}"
    )
if len(rendered_rule_maps) == 1 and len(rendered_loader_jobs) == 1:
    rendered_configmap_name = rendered_rule_maps[0]["metadata"]["name"]
    rendered_job_name = rendered_loader_jobs[0]["metadata"]["name"]
    if not re.fullmatch(r"mimir-rules-[a-z0-9]+", rendered_configmap_name):
        fail(f"Mimir rules ConfigMap is not content-hashed: {rendered_configmap_name!r}")
    if rendered_job_name != rendered_configmap_name:
        fail(
            "Mimir rules loader Job must share the generated ConfigMap name "
            f"({rendered_configmap_name!r}), got {rendered_job_name!r}"
        )
    if rendered_job_name == "mimir-config-loader":
        fail("Mimir rules loader must not use the immutable fixed name mimir-config-loader")

on_disk = {path.name for path in RULES.iterdir() if path.suffix in {".yaml", ".yml"}}
missing_from_configmap = on_disk - generator_files
missing_on_disk = generator_files - on_disk
for name in sorted(missing_from_configmap):
    fail(f"rules/{name}: present on disk but absent from mimir-rules ConfigMap")
for name in sorted(missing_on_disk):
    fail(f"rules/{name}: listed in mimir-rules ConfigMap but missing from rules/")

namespaces = {}
source_group_ids = set()
# Derive the expected set from every rule source on disk, not only the files
# currently listed in mimir-rules.files. That independence is what makes an
# omitted loader entry visible to the completeness checker.
for name in sorted(on_disk):
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
    groups = document.get("groups")
    if not isinstance(groups, list) or not groups:
        fail(f"{path}: groups must be a non-empty list")
        continue
    effective_namespace = (
        namespace.strip()
        if isinstance(namespace, str) and namespace.strip()
        else path.stem
    )
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("name"), str):
            fail(f"{path}: every group must have a non-empty name")
            continue
        group_id = (effective_namespace, group["name"].strip())
        if not group_id[1]:
            fail(f"{path}: every group must have a non-empty name")
        elif group_id in source_group_ids:
            fail(f"{path}: duplicate group identity {group_id!r}")
        else:
            source_group_ids.add(group_id)

declared_group_ids = set()
if not EXPECTED_GROUPS.is_file():
    fail(f"{EXPECTED_GROUPS}: missing independent expected-group set")
else:
    for line_number, raw_line in enumerate(EXPECTED_GROUPS.read_text().splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = raw_line.split("\t")
        if len(fields) != 2 or not all(field.strip() for field in fields):
            fail(f"{EXPECTED_GROUPS}:{line_number}: expected namespace<TAB>group")
            continue
        group_id = (fields[0].strip(), fields[1].strip())
        if group_id in declared_group_ids:
            fail(f"{EXPECTED_GROUPS}:{line_number}: duplicate group {group_id!r}")
        declared_group_ids.add(group_id)
    for group_id in sorted(source_group_ids - declared_group_ids):
        fail(
            f"{EXPECTED_GROUPS}: source group {group_id!r} is absent from the "
            "independent expected set"
        )
    for group_id in sorted(declared_group_ids - source_group_ids):
        fail(
            f"{EXPECTED_GROUPS}: expected group {group_id!r} has no source rule "
            "group"
        )

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

# The normal rule test runner intentionally covers a fixture-backed subset of
# production files; requiring a fixture for every rule would change that
# existing policy. Keep the subset internally complete, and require every
# changed production source to join it below. This catches a new rule being
# wired to the loader but silently omitted from its own test registration
# without turning the legacy fixture backlog into an immediate gate failure.
tested_rules = set()
test_files = {}
test_runner_text = ""
special_test_files = {
    "velero": ("velero_stale_test.yaml",),
    "mimir-loader": ("mimir-loader_test.yaml",),
}
if not TEST_RUNNER.is_file():
    fail(f"{TEST_RUNNER}: missing Mimir rule test runner")
else:
    test_runner_text = TEST_RUNNER.read_text()
    loop = re.search(
        r"(?m)^\s*for rule in\s+(.+?)\s*;\s*do\s*$", test_runner_text
    )
    if loop is None:
        fail(f"{TEST_RUNNER}: cannot find the fixture test loop")
    else:
        tested_rules = set(loop.group(1).split())
    for match in re.finditer(
        r"(?m)^\s*([A-Za-z0-9][A-Za-z0-9_-]*)\)\s+"
        r"test_file=([^\s;]+)\s*;;?\s*$",
        test_runner_text,
    ):
        rule, filename = match.groups()
        if rule in test_files:
            fail(f"{TEST_RUNNER}: duplicate fixture mapping for {rule!r}")
        test_files[rule] = filename
    if 'promtool check rules "$tmpdir/${rule}.yaml"' not in test_runner_text:
        fail(f"{TEST_RUNNER}: fixture loop does not check each rule file")
    if 'promtool test rules "$tmpdir/$test_file"' not in test_runner_text:
        fail(f"{TEST_RUNNER}: fixture loop does not run each rule fixture")


def check_fixture(rule, filename):
    fixture = TEST_FIXTURES / filename
    if not fixture.is_file():
        fail(f"{TEST_RUNNER}: fixture for {rule!r} is missing: {fixture}")
        return
    fixture_document = read_yaml(fixture)
    if not isinstance(fixture_document, dict):
        return
    fixture_rule_files = fixture_document.get("rule_files", [])
    expected_reference = f"../{rule}.yaml"
    if expected_reference not in fixture_rule_files:
        fail(
            f"{fixture}: test for {rule!r} must reference "
            f"{expected_reference!r}"
        )
    tests = fixture_document.get("tests")
    if not isinstance(tests, list) or not tests:
        fail(f"{fixture}: test for {rule!r} must contain non-empty tests")
        return

    # promtool accepts an empty test block, which would make registration a
    # box-ticking exercise. Require an explicit expected outcome and at least
    # one positive result; an empty exp_alerts list is still meaningful as an
    # additional no-alert assertion, but not as the fixture's only assertion.
    assertions = 0
    positive_assertions = 0
    for case in tests:
        if not isinstance(case, dict):
            continue
        for test_key, expected_key in (
            ("alert_rule_test", "exp_alerts"),
            ("promql_expr_test", "exp_samples"),
        ):
            entries = case.get(test_key, [])
            if not isinstance(entries, list):
                continue
            for entry in entries:
                if not isinstance(entry, dict) or expected_key not in entry:
                    continue
                assertions += 1
                if entry[expected_key]:
                    positive_assertions += 1
    if assertions == 0:
        fail(
            f"{fixture}: test for {rule!r} must contain an explicit "
            "exp_alerts or exp_samples assertion"
        )
    elif positive_assertions == 0:
        fail(
            f"{fixture}: test for {rule!r} must assert at least one "
            "non-empty exp_alerts or exp_samples result"
        )


for rule in sorted(tested_rules):
    source = RULES / f"{rule}.yaml"
    if not source.is_file():
        fail(f"{TEST_RUNNER}: tested rule {rule!r} has no source file {source}")
    filename = test_files.get(rule)
    if filename is None:
        fail(f"{TEST_RUNNER}: tested rule {rule!r} has no case fixture mapping")
        continue
    check_fixture(rule, filename)

for rule, filenames in special_test_files.items():
    for filename in filenames:
        source_reference = f'"$RULE_DIR/{rule}.yaml"'
        fixture_reference = f'"$RULE_DIR/tests/{filename}"'
        if source_reference not in test_runner_text:
            fail(
                f"{TEST_RUNNER}: special test for {rule!r} does not invoke "
                f"{source_reference}"
            )
        if fixture_reference not in test_runner_text:
            fail(
                f"{TEST_RUNNER}: special test for {rule!r} does not invoke "
                f"{fixture_reference}"
            )
        check_fixture(rule, filename)

for rule in sorted(set(test_files) - tested_rules):
    fail(f"{TEST_RUNNER}: case fixture mapping for untested rule {rule!r}")

for rule in sorted(changed_rules):
    if rule not in tested_rules and rule not in special_test_files:
        fail(
            f"{RULES / (rule + '.yaml')}: changed production rule is not "
            "registered in rules/tests/run.sh with a fixture"
        )

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
