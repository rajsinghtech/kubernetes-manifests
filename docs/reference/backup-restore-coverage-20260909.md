# Backup and restore coverage reference — 2026-09-09

This is a point-in-time record of the backup evidence and decisions available
on 2026-09-09 UTC. It is not a promise that the live fleet still has the same
objects, schedules, images, or storage. Recheck the live objects before using
this as an incident procedure. No credential values are recorded here.

## Executive state at the date

* Kopiur restore `homeassistant-config-restore-content-r3` completed with
  `RestoreSucceeded` on `spark-1`, exit code 0, and no OOM. It proved file data
  restoration for one Home Assistant volume; it did not prove metadata or
  application recovery.
* Kopiur’s mechanism is credible, but its fleet coverage is exactly one
  workload/volume: St. Petersburg `home-assistant/homeassistant-config`.
* Velero backs up selected Kubernetes objects and supported pod volumes through
  its node-agent/Kopia filesystem-backup path. It cannot filesystem-back up a
  `hostPath`, including a `local-path` volume whose PV resolves to `hostPath`.
* The initial eight-PVC candidate list resolves to four genuine gaps, three
  deliberate Immich exclusions, and one candidate corrected to not-a-gap after
  accounting for Woodpecker’s PostgreSQL protection.

## Kopiur restore verification

### The r3 shape

The proof used an exact, named `Snapshot`, a read-only `ClusterRepository`
projection, an isolated namespace, and a newly created target PVC. It did not
resolve a moving policy or write to the live Home Assistant PVC. The historical
object shape was:

```yaml
---
# The r2 content proof restored the files but failed while applying the root
# directory mtime. This retry skips all ownership, permission, and timestamp
# metadata so a successful run is an explicit file-data proof only.
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Restore
metadata:
  name: homeassistant-config-restore-content-r3
  namespace: kopiur-restore-proof-20260908-ha
spec:
  source:
    snapshotRef:
      name: homeassistant-config-20260908034331
      namespace: home-assistant
  repository:
    kind: ClusterRepository
    name: kopiur-stpetersburg-restore-readonly
  credentialProjection:
    enabled: true
  target:
    pvc:
      name: homeassistant-config-restore-content-r3
      accessModes:
        - ReadWriteOnce
      capacity: 10Gi
      storageClassName: local-path
  mover:
    inheritSecurityContextFrom:
      snapshot: {}
  options:
    enableFileDeletion: false
    ignoreErrors: false
    ignorePermissionErrors: false
    parallel: 1
    skipExisting: false
    skipOwners: true
    skipPermissions: true
    skipTimes: true
    writeFilesAtomically: true
  policy:
    onMissingSnapshot: Fail
    waitTimeout: 5m
  failurePolicy:
    backoffLimit: 0
    activeDeadlineSeconds: 1800
    podStartupDeadlineSeconds: 300
```

The source snapshot was the retained Kopiur snapshot for the
`home-assistant/homeassistant-config` source. `credentialProjection` lets the
isolated namespace use the explicitly permitted read-only repository view; it
does not make that view a second writer.

### Checklist

Use the canonical cluster helper and inspect, do not assume, each boundary:

```bash
RESTORE_NS=kopiur-restore-proof-20260908-ha
RESTORE=homeassistant-config-restore-content-r3
TARGET=homeassistant-config-restore-content-r3

tools/kc.sh sp -n home-assistant get snapshot.kopiur.home-operations.com \
  homeassistant-config-20260908034331 -o yaml
tools/kc.sh sp get clusterrepository.kopiur.home-operations.com \
  kopiur-stpetersburg-restore-readonly -o yaml
tools/kc.sh sp -n "$RESTORE_NS" get restore.kopiur.home-operations.com \
  "$RESTORE" -o yaml
tools/kc.sh sp -n "$RESTORE_NS" get pvc "$TARGET" -o wide
tools/kc.sh sp -n "$RESTORE_NS" get jobs,pods -o wide
tools/kc.sh sp -n "$RESTORE_NS" get events --sort-by=.lastTimestamp
```

For the mover pod identified by the `jobs,pods` output, inspect its actual
placement, termination state, logs, and events:

```bash
tools/kc.sh sp -n "$RESTORE_NS" get pod <mover-pod> \
  -o jsonpath='{.spec.nodeName}{"\n"}{.status.containerStatuses[*].state.terminated}{"\n"}'
tools/kc.sh sp -n "$RESTORE_NS" describe pod <mover-pod>
tools/kc.sh sp -n "$RESTORE_NS" logs pod/<mover-pod> --all-containers
```

A passing content restore requires all of the following:

1. The exact source `Snapshot` resolves and is `Succeeded`, with non-zero
   file statistics. A zero-file result is not evidence of a useful snapshot.
2. The `Restore` has `status.phase: Completed` and a true `RestoreSucceeded`
   result, with no restore errors or warnings.
3. The target PVC is `Bound` to a target PV. It is a new empty claim, not the
   live source claim or a claim left partially populated by an earlier try.
4. The mover pod’s actual `nodeName` is not `spark-0`, its container exits with
   code 0, and neither its status nor its events show `OOMKilled` or a node
   capacity failure.
5. An independent read-only verifier compares the restored file inventory and
   file contents (paths, types, sizes, and hashes or equivalent byte checks)
   against the source snapshot’s expected data. The verifier must report the
   scope it checked; a successful CR alone is not a file-content comparison.

r3 met these criteria for repository access, exact snapshot resolution,
enumeration, and file-data restoration. It ran on `spark-1` and exited 0
without OOM.

### Failed Restore objects are terminal

`status.phase: Failed` is the terminal result for that `Restore` object. A
spec patch does not turn it into a new attempt and must not be used as a retry
mechanism. Preserve the failed object and its logs as evidence, then create a
new `Restore` with a new name and a new target PVC. If the retry uses a new
namespace, add that namespace to the `ClusterRepository.spec.allowedNamespaces`
list and give it both required namespace allowances before the GitOps
reconcile. Do not reuse a partially written target claim.

### Ownership-preserving restores need three separate gates

The r3 object intentionally skipped ownership, permission, and timestamp
metadata. When metadata preservation is the goal, the isolated namespace must
have both the Kubernetes Pod Security allowance and Kopiur’s mover allowance:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <isolated-restore-namespace>
  labels:
    pod-security.kubernetes.io/enforce: privileged
  annotations:
    kopiur.home-operations.com/privileged-movers: "true"
```

The `Restore` must also request an explicit root mover and retain Kopiur’s
privileged-mode gate:

```yaml
mover:
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    runAsNonRoot: false
  privilegedMode: true
```

`privilegedMode: true` is not a substitute for the root security context. It
permits the privileged mover path but does not set the mover’s UID or GID. The
ownership attempt demonstrated this: the mover could reach the restore but an
inherited non-root identity could not apply the original ownership. For this
Home Assistant source, relying on `inheritSecurityContextFrom.snapshot: {}`
also does not guarantee a pinned UID; the image identity was non-root. Keep
the source mount read-only, and use the explicit root fields only in an
isolated, approved restore namespace.

### Keep restore movers off the memory-starved Spark

At the time of r3, `spark-0` had only 0.9% available memory. The read-only
`ClusterRepository` projection therefore carried an exclusion and bounded
resources for restore movers:

```yaml
moverDefaults:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/hostname
                operator: NotIn
                values:
                  - spark-0
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

This constraint must be verified against the mover pod’s actual `nodeName`; a
desired affinity alone is not proof. An OOM caused by node capacity can look
like a restore failure if placement and events are not checked separately.

## What the r3 result does and does not prove

| Claim | Result on 2026-09-09 |
| --- | --- |
| Repository can be reached through the approved read-only projection | Proven |
| The named snapshot resolves and can be enumerated | Proven |
| File data can be restored to a new PVC | Proven for `home-assistant/homeassistant-config` |
| UID/GID ownership is restored | Not proven; r3 set `skipOwners: true` |
| Permission bits are restored | Not proven; r3 set `skipPermissions: true` |
| Timestamps are restored | Not proven; r3 set `skipTimes: true` |
| Home Assistant starts and is usable from restored data | Not proven |

The mechanism claim and the coverage claim are different: r3 makes Kopiur’s
repository access and file-data path credible, but it covers one workload, not
the fleet.

## Fleet coverage snapshot

### Velero’s positive scope

Velero schedules select Kubernetes API objects in their included namespaces.
For volumes that the node-agent filesystem-backup path supports, the data
unit is a `PodVolumeBackup` tied to the source Pod and volume, not a bare PVC
or a CSI `VolumeSnapshot`. For a data-coverage claim, inspect the parent
`Backup` and the child PVBs; a useful PVB is `Completed` with matching
`bytesDone` and `totalBytes`. A parent `Backup` phase of `Completed` can still
have warnings or no usable volume-data child.

As observed in this fleet, Velero has byte-complete config-volume coverage on
the Ottawa and Robbinsdale Home Assistant Ceph/SMB paths. St. Petersburg’s
Home Assistant object backup is scheduled, but its local-path data is not in
that Velero backup. PostgreSQL Barman/CloudNativePG backups and other
application-native copies are separate mechanisms and must not be counted as
Velero filesystem coverage.

### Kopiur’s actual fleet scope

| Cluster | Kopiur state on 2026-09-09 | Coverage verdict |
| --- | --- | --- |
| St. Petersburg | Namespaced `Repository`/`SnapshotPolicy` for `home-assistant/homeassistant-config`, stored in the dedicated `kopiur-stpetersburg` repository | Exactly one protected volume/workload |
| Ottawa | Read-only Kopiur `ClusterRepository` views used to read Velero-owned Kopia data for restore work | No Kopiur-protected workload; this is a view over Velero data |
| Robbinsdale | No Kopiur CRDs | No Kopiur coverage |

Thus the credible statement is “Kopiur restored file data from the approved
repository.” The stronger statement “Kopiur covers the fleet” is false on this
date.

## Why Velero cannot help with local-path/hostPath

The local-path provisioner produces a PV whose backing volume is `hostPath`.
Velero’s filesystem backuper rejects hostPath at
`pkg/podvolume/backupper.go:347`. This is an implementation boundary, not a
missing setting. Velero cannot capture these volumes through a resource policy,
an opt-in annotation, a different BackupStorageLocation, or a CSI snapshot
configuration. No configuration fix changes that.

For a local-path/hostPath volume, the operational question is always “what
else protects this data?”—for example, a supported storage migration or a
separate direct-copy mechanism—not “how do I make Velero capture it?”

## Vault exposure recorded on the date

This is a custom single-replica application named Vault, not HashiCorp Vault.
There is no HashiCorp unseal path to use during recovery.

* Its data shape is `keiretsu/data-vault-0`, a 5Gi
  `ceph-block-replicated` PVC.
* The private Git copy’s automatic backups stop at 2026-05-11. They run from
  Raj’s Mac, not from the cluster.
* The registry returned `404 NAME_UNKNOWN` for the tag/list request, a tag
  manifest request, the exact digest manifest request, and the catalog
  request. The image therefore cannot be redeployed even by digest.

This leaves two independent single points of failure in one application: the
runtime image cannot currently be fetched, and the application data has no
verified independent recovery copy. Ceph replication is not a substitute for
either a recoverable image artifact or a backup.

## Gap ledger and the two misleading counts

### The original eight-PVC candidate tally

The “8 PVCs” figure was an initial candidate list, not eight identical
failures. The rows and verdicts were:

| Candidate | Location | Verdict on 2026-09-09 | Reason |
| --- | --- | --- | --- |
| Vault data | `keiretsu/data-vault-0` | Genuine gap | Single-replica custom app; image is unavailable and no verified independent data recovery exists |
| Firefly uploads | `firefly/firefly-upload` | Genuine gap | Database protection does not cover the upload PVC |
| Kometa config | Ottawa `media/kometa` | Genuine gap pending a byte-complete protected copy | Schedule membership alone is not data proof |
| Kometa config | Robbinsdale `media/kometa` | Genuine gap pending recovery from the failed/incomplete PVB condition | A scheduled attempt is not a successful protected copy |
| Woodpecker server state | `woodpecker` server PVC | **Not a gap after correction** | Server state is protected in `woodpecker-postgres` through CloudNativePG/Barman backups |
| Immich library | Ottawa `immich/immich-library` | Deliberate gap | Photo library backup was explicitly declined |
| Immich library | Robbinsdale `immich/immich-library` | Deliberate gap | Photo library backup was explicitly declined |
| Immich second photo store | Robbinsdale `immich/immich-pics-v2` | Deliberate gap | Photo library backup was explicitly declined |

The corrected accounting is therefore four genuine gaps, three deliberate
Immich exclusions, and one candidate removed as a gap. A seven-row list of
gaps plus deliberate exclusions is the final ledger; the earlier “eight” is
retained here so the correction is auditable.

### Disposable exclusions not included in that ledger

These names and classes were excluded because they are rebuildable, scratch,
test, or otherwise intentionally disposable. They must not be silently counted
as durable application-data coverage:

* Woodpecker agent/workspace/cache/runner claims, including
  `workspace-nix-cache` and per-workflow workspace/runner claims.
* `kbench-*` disk-test PVCs and other test PVCs.
* Tailscale state volumes, including `tailscale-state` in the test workloads.
* AI model-weight caches `llama-cpp-models` and `models-vllm-*`.
* Telemetry PVCs and their rebuildable TSDB/cache state.
* Temporary restore claims `home-config-restored-r2`,
  `homeassistant-config-restore-content-r2`, and
  `homeassistant-config-restore-content-r3`.
* Non-PVC `emptyDir` scratch such as AirConnect, Homer, Frigate, CLIProxy, and
  the accepted Pi-hole state.

`cartography/data-neo4j-0` was not silently classified as disposable; it
remained an ownership/classification question.

### What km#2729 actually counted

km#2729’s “18 namespaces” was a count of namespaces lacking a Velero
**Schedule**, not a count of uncovered PVCs. It neither identified eight PVCs
nor proved that every PVC in those namespaces lacked a data mechanism. To
re-derive the real number, enumerate PVCs by cluster and namespace, map each to
the applicable Velero Schedule, inspect completed PVB data, then apply the
explicit deliberate/disposable verdicts above. Never substitute the namespace
count for the PVC ledger.

## Source manifests

* [r3 Restore object](../../kubernetes/apps/base/kopiur/kopiur-restore-proof/restore-content-r3.yaml)
* [r3 isolated namespace](../../kubernetes/apps/base/kopiur/kopiur-restore-proof/namespace.yaml)
* [St. Petersburg read-only repository projection](../../kubernetes/apps/base/kopiur/kopiur-stpetersburg-restore-projection/clusterrepository.yaml)
* [Home Assistant Kopiur notes](../../kubernetes/apps/base/home-assistant/home-assistant/kopiur/README.md)
* [Velero PVC schedule exemptions](../../kubernetes/apps/base/velero/velero/pvc-schedule-exemptions.yaml)
