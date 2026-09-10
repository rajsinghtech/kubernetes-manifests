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
    @staticmethod
    def bound_pvc(
        namespace: str = "keiretsu",
        name: str = "data-vault-0",
        storage_class: str = "ceph-block-replicated",
        volume_name: str = "pv-data-vault-0",
        annotations: dict[str, str] | None = None,
    ) -> dict:
        return {
            "metadata": {
                "namespace": namespace,
                "name": name,
                "annotations": annotations or {},
            },
            "spec": {
                "storageClassName": storage_class,
                "volumeName": volume_name,
            },
            "status": {"phase": "Bound"},
        }

    @staticmethod
    def csi_pv(name: str = "pv-data-vault-0") -> dict:
        return {
            "metadata": {"name": name},
            "spec": {"csi": {"driver": "rook-ceph.rbd.csi.ceph.com"}},
        }

    @staticmethod
    def mounted_pod(annotations: dict[str, str] | None = None) -> dict:
        return {
            "metadata": {
                "namespace": "keiretsu",
                "name": "vault-0",
                "labels": {"app": "vault"},
                "annotations": annotations or {},
            },
            "status": {"phase": "Running"},
            "spec": {
                "volumes": [
                    {
                        "name": "data",
                        "persistentVolumeClaim": {"claimName": "data-vault-0"},
                    }
                ]
            },
        }

    @staticmethod
    def schedule(
        name: str = "vault-backup",
        default_volumes: bool | None = True,
    ) -> dict:
        template = {"includedNamespaces": ["keiretsu"]}
        if default_volumes is not None:
            template["defaultVolumesToFsBackup"] = default_volumes
        return {"metadata": {"name": name}, "spec": {"template": template}}

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

    def test_no_schedule_gap_clears_when_schedule_covers_pvc(self) -> None:
        pvc = self.bound_pvc()
        pv = self.csi_pv()
        pod = self.mounted_pod()

        gaps, structural = probe.evaluate_pvc_selection([pvc], [pv], [pod], [])
        self.assertEqual(
            [(gap.pvc, gap.reason) for gap in gaps],
            [("data-vault-0", "no_schedule")],
        )
        self.assertEqual(structural, [])

        gaps, structural = probe.evaluate_pvc_selection(
            [pvc], [pv], [pod], [self.schedule()]
        )
        self.assertEqual(gaps, [])
        self.assertEqual(structural, [])

    def test_no_volume_selection_gap_clears_when_pod_annotation_covers_it(self) -> None:
        pvc = self.bound_pvc(namespace="media", name="kometa", volume_name="pv-kometa")
        pv = self.csi_pv("pv-kometa")
        pod = self.mounted_pod()
        pod["metadata"]["namespace"] = "media"
        pod["spec"]["volumes"][0]["persistentVolumeClaim"]["claimName"] = "kometa"
        schedule = self.schedule(name="media-config-backup", default_volumes=False)
        schedule["spec"]["template"]["includedNamespaces"] = ["media"]

        gaps, structural = probe.evaluate_pvc_selection(
            [pvc], [pv], [pod], [schedule]
        )
        self.assertEqual(
            [(gap.pvc, gap.reason) for gap in gaps],
            [("kometa", "no_volume_selection")],
        )
        self.assertEqual(structural, [])

        pod["metadata"]["annotations"] = {
            "backup.velero.io/backup-volumes": "data"
        }
        gaps, structural = probe.evaluate_pvc_selection(
            [pvc], [pv], [pod], [schedule]
        )
        self.assertEqual(gaps, [])
        self.assertEqual(structural, [])

    def test_completed_pod_still_proves_volume_selection(self) -> None:
        pvc = self.bound_pvc(namespace="media", name="kometa", volume_name="pv-kometa")
        pv = self.csi_pv("pv-kometa")
        pod = self.mounted_pod(annotations={"backup.velero.io/backup-volumes": "data"})
        pod["metadata"]["namespace"] = "media"
        pod["spec"]["volumes"][0]["persistentVolumeClaim"]["claimName"] = "kometa"
        pod["status"]["phase"] = "Succeeded"
        schedule = self.schedule(name="media-config-backup", default_volumes=False)
        schedule["spec"]["template"]["includedNamespaces"] = ["media"]

        gaps, structural = probe.evaluate_pvc_selection(
            [pvc], [pv], [pod], [schedule]
        )
        self.assertEqual(gaps, [])
        self.assertEqual(structural, [])

    def test_explicit_pvc_exclusion_is_not_a_selection_gap(self) -> None:
        pvc = self.bound_pvc()
        pvc["metadata"]["labels"] = {"velero.io/exclude-from-backup": "true"}
        pv = self.csi_pv()
        pod = self.mounted_pod()
        schedule = self.schedule()

        gaps, structural = probe.evaluate_pvc_selection(
            [pvc], [pv], [pod], [schedule]
        )
        self.assertEqual(gaps, [])
        self.assertEqual(structural, [])

    def test_structural_hostpath_is_separate_from_selection_gap(self) -> None:
        pvc = self.bound_pvc(
            namespace="home-assistant",
            name="homeassistant-config",
            storage_class="local-path",
            volume_name="pv-homeassistant",
        )
        pv = {
            "metadata": {"name": "pv-homeassistant"},
            "spec": {"hostPath": {"path": "/var/lib/local-path"}},
        }
        schedule = self.schedule(name="home-assistant-backup")
        schedule["spec"]["template"]["includedNamespaces"] = ["home-assistant"]

        gaps, structural = probe.evaluate_pvc_selection(
            [pvc], [pv], [], [schedule]
        )
        self.assertEqual(gaps, [])
        self.assertEqual(
            [(item.pvc, item.reason) for item in structural],
            [("homeassistant-config", "hostpath")],
        )

    def test_selection_metric_has_required_labels_and_reason(self) -> None:
        gap = probe.PVCSelectionGap(
            "keiretsu", "data-vault-0", "ceph-block-replicated", "no_schedule"
        )
        metrics = probe.render_selection_metrics(
            [gap], [], True, 100.0, 100.0, "talos-ottawa"
        )
        self.assertIn(
            'velero_pvc_backup_selection_gap{cluster="talos-ottawa",namespace="keiretsu",'
            'pvc="data-vault-0",reason="no_schedule",storage_class="ceph-block-replicated"} 1',
            metrics,
        )


if __name__ == "__main__":
    unittest.main()
