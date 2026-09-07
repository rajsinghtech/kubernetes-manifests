# Velero backups need an independent object store

Status: recommended decision, 2026-09-04

## Decision

Velero's disaster-recovery target must move to an independently operated
off-cluster S3 service. A separately operated Garage cluster is also
acceptable if it is not part of the current Garage federation or storage
estate. The current Garage target is an interim, explicitly accepted risk
until that target exists and a restore has been verified against it.

This document records the posture; it does not change the live
`BackupStorageLocation`. The migration is a separate GitOps change and must
keep the current target until the new target has a successful restore drill.

## Facts at decision time

The live observations below were made on 2026-09-04 UTC.

| Fact | Current state |
| --- | --- |
| Velero target | `velero-system/garage`, provider `aws`, bucket `velero`, per-site prefix (`ottawa`, `robbinsdale`, or `stpetersburg`) |
| S3 path | `http://garage-gateway.garage.svc.cluster.local:3900`; the `bhaiya-garage-kopia` repository is `Ready` on this BSL |
| Bucket object | `GarageBucket/garage/velero`, `globalAlias: velero`, `maxSize: 1Ti` |
| Current bucket usage | 30,760 objects and 308,047,420,448 bytes (286.9 GiB); usage is approximately 28% of the configured byte quota |
| Garage topology | replication factor 3, `consistent` read-after-write (required by Kopia maintenance; see #575), Ottawa/Robbinsdale/St. Petersburg federated zones; Ottawa currently has five storage nodes and two gateway replicas |
| Independent target | None. All three live `GarageBucket/velero` objects report the same global bucket ID, and all three BSLs use the same bucket and gateway service name with only the prefix changed |

Garage's remote zones and replication protect against selected node or site
losses. They do not make a second backup system: a Garage-wide outage,
federation/control-plane failure, deletion, or corruption can remove both
Velero's backup metadata and its Kopia data path. Another bucket, gateway pod,
or namespace in this same estate would have the same common dependency.

The repository configuration is visible in
[`velero/helmrelease.yaml`](../../kubernetes/apps/base/velero/velero/helmrelease.yaml),
[`garage-velero-bucket/bucket.yaml`](../../kubernetes/apps/base/garage/garage-velero-bucket/bucket.yaml),
and [`garagecluster.yaml`](../../kubernetes/apps/base/garage/garage/garagecluster.yaml).
Velero has no `volumeSnapshotLocation`; node-agent Kopia filesystem backups
write through the single Garage BSL.

One non-protected file-bearing snapshot has since passed a read-only Kopia
cryptographic verification: 217 files, 125 directories, and 11,565,119 bytes,
matching its completed PodVolumeBackup claim. That proves that snapshot's
stored data is readable. It does not prove every backup, or Velero's complete
Kubernetes restore orchestration, and it does not remove the shared-failure-
domain risk.

## Restore runbook

`PodVolumeBackup` is tied to a source Pod. Restoring a PVC (even with a PV)
without the corresponding Pod does not create the PodVolumeRestore path; the
result can be an empty or unusable volume. Do not use a PVC-only restore.

Before starting, select a specific `Backup`, reject `Failed` and
`PartiallyFailed` backups, and inspect every consequential PVC's PVB. Each
must be `Completed` with `bytesDone == totalBytes`; `itemsBackedUp ==
totalItems` is only a metadata count.

For a namespace-mapped recovery, use an isolated target and restore the
complete dependency graph together. With Velero 1.18.x, the equivalent CLI
shape is:

```text
velero restore create <restore-name> \
  --from-backup <backup-name> \
  --include-namespaces bhaiya \
  --namespace-mappings bhaiya:<target-namespace> \
  --include-resources pods,persistentvolumeclaims,persistentvolumes \
  --include-cluster-resources=true \
  --restore-volumes=true \
  --existing-resource-policy=none \
  --wait
```

The `persistentvolumes` inclusion is intentional: Velero must process the
backed-up PV so the restored PVC can bind to a new PV rather than retain the
old source `volumeName`. Audit the selected backup before allowing any other
cluster-scoped resource; do not restore CRDs, RBAC, webhooks, or StorageClasses
as a side effect of this runbook.

Afterward, verify all of the following before calling the recovery successful:

1. The `Restore` is complete with no errors or warnings.
2. Every expected target PVC is `Bound` to a restored PV.
3. Every PVC-backed source Pod has a corresponding `PodVolumeRestore` in
   `Completed` state, with the expected source PVB and target PVC.
4. The restored Pods run and an application-level, read-only file check
   confirms the expected data. A successful restore object or byte claim alone
   is not sufficient.

The same checks must be repeated after the BSL migration using a backup stored
in the independent target. Until then, the current Garage-backed backups are
useful operational recovery material but are not independent disaster
recovery coverage.

## Consequences and follow-up

- Provision the independent S3/Garage target with its own credentials,
  retention, and—where available—versioning or immutability.
- Add the new BSL and credentials through GitOps, then run an isolated restore
  drill before changing the default location or retiring the current history.
- Keep treating Garage health and `Completed`/byte counters as necessary but
  insufficient signals; periodically verify a real snapshot and the full
  Pod/PVC/PV restore graph.
