#!/usr/bin/env python3
import importlib.util
import pathlib
import ssl
import sys
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).parents[1] / "probe.py"
SPEC = importlib.util.spec_from_file_location("probe", MODULE_PATH)
assert SPEC and SPEC.loader
probe = importlib.util.module_from_spec(SPEC)
sys.modules["probe"] = probe
SPEC.loader.exec_module(probe)


class ProbeTest(unittest.TestCase):
    def test_normalizes_implicit_docker_hub_names(self) -> None:
        image = probe.normalize_image("alpine")
        self.assertEqual(image.registry, "docker.io")
        self.assertEqual(image.repository, "library/alpine")
        self.assertEqual(image.reference, "latest")

    def test_preserves_explicit_registry_and_digest(self) -> None:
        image = probe.normalize_image(
            "oci.cdn.keiretsu.top/keiretsu/vault@sha256:abc"
        )
        self.assertEqual(image.registry, "oci.cdn.keiretsu.top")
        self.assertEqual(image.repository, "keiretsu/vault")
        self.assertEqual(image.reference, "sha256:abc")
        self.assertIn("/v2/keiretsu/vault/manifests/sha256:abc", image.manifest_url)

    def test_collects_init_regular_and_ephemeral_references(self) -> None:
        pods = [
            {
                "metadata": {
                    "namespace": "demo",
                    "name": "worker-0",
                    "ownerReferences": [
                        {"controller": True, "kind": "StatefulSet", "name": "worker"}
                    ],
                },
                "spec": {
                    "initContainers": [{"name": "init", "image": "busybox:latest"}],
                    "containers": [{"name": "main", "image": "example/app:v1"}],
                    "ephemeralContainers": [
                        {"name": "debug", "image": "alpine:3.24"}
                    ],
                },
            }
        ]
        references = probe.workload_references(pods)
        self.assertEqual(
            [(item.container_type, item.container) for item in references],
            [("init", "init"), ("regular", "main"), ("ephemeral", "debug")],
        )
        self.assertTrue(all(item.owner_name == "worker" for item in references))

    def test_only_probes_the_internal_registry(self) -> None:
        with mock.patch.object(
            probe, "probe_manifest", return_value="present"
        ) as check:
            statuses = probe.probe_images(
                {
                    "oci.cdn.keiretsu.top/keiretsu/app:v1",
                    "ghcr.io/example/app:v1",
                    "alpine:3.18",
                },
                ssl.create_default_context(),
                workers=2,
            )

        self.assertEqual(
            statuses,
            {
                "oci.cdn.keiretsu.top/keiretsu/app:v1": (
                    "present",
                    "oci.cdn.keiretsu.top",
                )
            },
        )
        check.assert_called_once()

    def test_missing_status_includes_actionable_reference_labels(self) -> None:
        reference = probe.WorkloadReference(
            image="oci.cdn.keiretsu.top/keiretsu/vault:old",
            namespace="keiretsu",
            pod="vault-0",
            container="vault",
            container_type="regular",
            owner_kind="StatefulSet",
            owner_name="vault",
        )
        metrics = probe.render_metrics(
            [reference],
            {reference.image: ("missing", "oci.cdn.keiretsu.top")},
            True,
            100.0,
            0.5,
            100.0,
        )
        self.assertIn('status="missing"', metrics)
        self.assertIn('namespace="keiretsu"', metrics)
        self.assertIn('pod="vault-0"', metrics)
        self.assertIn("running_workload_image_registry_probe_references", metrics)

    def test_unmonitored_registry_reference_is_not_emitted(self) -> None:
        internal = probe.WorkloadReference(
            image="oci.cdn.keiretsu.top/keiretsu/app:v1",
            namespace="demo",
            pod="app-0",
            container="app",
            container_type="regular",
            owner_kind="StatefulSet",
            owner_name="app",
        )
        external = probe.WorkloadReference(
            image="ghcr.io/example/app:v1",
            namespace="demo",
            pod="external-0",
            container="app",
            container_type="regular",
            owner_kind="StatefulSet",
            owner_name="external",
        )
        metrics = probe.render_metrics(
            [internal, external],
            {internal.image: ("present", "oci.cdn.keiretsu.top")},
            True,
            100.0,
            0.5,
            100.0,
        )

        self.assertIn('image="oci.cdn.keiretsu.top/keiretsu/app:v1"', metrics)
        self.assertNotIn('image="ghcr.io/example/app:v1"', metrics)
        self.assertIn("running_workload_image_registry_probe_images 1", metrics)


if __name__ == "__main__":
    unittest.main()
