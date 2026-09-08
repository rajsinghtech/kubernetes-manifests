# Proposal: export Velero's intended pod-volume coverage

## Problem

`VeleroScheduleVolumeCoverageRegressed` currently compares the newest
successful Backup's completed `PodVolumeBackup` count with the previous
successful Backup's count. That is useful for detecting a `1-of-37` failure,
but it is not an intended-coverage contract. A resource policy can
legitimately reduce the selected set between runs. Robbinsdale's `home-backup`
demonstrated this when a policy began excluding seven `emptyDir` volumes: the
durable PVCs were still backed up, but the historical-count rule remained
red.

The current warning in `rules/velero-integrity.yaml` is the safe interim
behavior. Removing it would restore the blind spot that motivated the alert.
The durable fix is to compare actual PVBs with the set Velero intended to
select for that specific Backup, after applying the same policy evaluation
that selected the volumes.

## Scope investigation

This fact is not available to the current Mimir or kube-state-metrics
configuration:

* A Backup contains `spec.defaultVolumesToFsBackup` and a reference to the
  resource policy ConfigMap. It does not contain the policy's evaluated
  volume set.
* Velero v1.18.2 evaluates each Pod volume against the referenced policy and
  the resolved PVC/PV while the Backup runs. Its `BackupStatus` contains phase,
  timestamps, warnings, errors, progress, and snapshot counters, but no
  selected/skipped pod-volume identities or expected PVB count.
* The live `bhaiya-backup-20260908080002` confirms this shape: its status keys
  are only `completionTimestamp`, `expiration`, `formatVersion`, `hookStatus`,
  `phase`, `progress`, `startTimestamp`, and `version`. Its spec has the policy
  reference, but the post-policy result is absent.
* Velero logs contain transient messages such as `Perform fs-backup action`
  and `Skip fs-backup action`, but logs are not a durable metric source and
  cannot be joined reliably to the retained Backup/PVB population.
* kube-state-metrics custom-resource-state configuration can expose fields
  that already exist on a CR. It cannot evaluate a referenced ConfigMap
  policy against the live Pod/PVC/PV set, and adding another label for the
  policy reference would not create the missing fact.

The existing `velero_cr_podvolumebackup_info` metric is sufficient for the
actual side of the comparison. Its newest-PVB join is already used by
`VeleroPodVolumeBackupFailed` and is the correct non-latching pattern; this
proposal does not replace or duplicate that exporter.

Therefore this is not a KSM-only or Mimir-side change. Reimplementing
Velero's policy evaluator in Bhaiya would duplicate upstream semantics and
would drift whenever Velero adds policy conditions or volume mechanisms.

## Proposed owner and contract

The Velero backup emitter should persist the result of its own selection
evaluation on each Backup, before it starts waiting for PVB completion. The
minimum useful contract is:

```yaml
status:
  podVolumeBackupSelection:
    phase: Complete       # Complete, Empty, or Unknown
    evaluatedAt: "..."
    policyResourceVersion: "..."
    expected:
      - podNamespace: bhaiya
        podName: sandbox-...
        podUID: "..."
        volume: home
```

The identity should use the same `(pod UID, volume name)` tuple that a PVB
already exposes, with namespace/name for operator readability. The policy
resource version makes a later policy change visible and prevents a responder
from treating two counts as comparable without knowing which policy was
evaluated. A count-only field may be a first compatibility step, but the
identity set is the safer final contract: it catches a wrong-volume
substitution even when the count is unchanged.

The status must distinguish `Empty` (policy evaluation completed and selected
no data volumes) from `Unknown` (evaluation failed or the field is unavailable).
The alert must never interpret `Unknown` as zero. A policy-evaluation error
should remain an observability failure, not become a false claim that the
Backup was intentionally volume-less.

The next metrics layer can then be small and owned by the manifests repo:

* KSM exports one expected-volume series per persisted identity, keyed by
  Backup UID/schedule, pod UID, and volume; it also exports selection phase
  and evaluation timestamp.
* The Mimir rule joins expected identities to completed, byte-complete PVBs
  for the same Backup. It alerts on expected identities without a matching
  PVB, while retaining the current zero-volume guard for schedules that have
  no expected set.
* Promtool tests cover `1-of-37` (still alerts), intentional `emptyDir`
  exclusions (does not alert), a changed policy with a new intended set, an
  `Empty` selection, and `Unknown` selection (which must not page as zero).

This keeps policy evaluation in Velero, CR-to-metric projection in KSM, and
alert semantics in Mimir. No component has to infer intent from last week's
PVB count.

### File-level ownership

To avoid parallel half-implementations, the work should be partitioned as
follows:

* Velero upstream owns the selection evaluation and persisted Backup status
  contract. No Bhaiya or manifests component should reimplement Velero's
  resource-policy evaluator.
* `kubernetes/apps/base/monitoring/monitoring-common/app/kube-state-metrics-config.yaml`
  owns projection of the new persisted fields, alongside the existing PVB
  projection. It does not own policy evaluation.
* `kubernetes/apps/base/mimir/mimir-ottawa/rules/velero-integrity.yaml` and
  its promtool tests own the eventual join and alert migration. They should
  not grow a second volume-set emitter.

The existing PVB metric and failure rule remain unchanged while the upstream
contract is absent.

## St Petersburg and unsupported mechanisms

An intended set is not a claim that the cluster has a mechanism capable of
capturing it. St Petersburg's local-path volumes currently have no backup
mechanism (#2877). If Velero's policy evaluation says a durable volume is
intended but no PVB mechanism can fulfill it, the expected series should
remain present and the coverage alert should remain actionable. A separate
capability/unsupported-volume signal can explain the cause; subtracting those
volumes from intended coverage would hide the gap.

## Compatibility and implementation sequence

1. Add the persisted selection status to Velero upstream (including CRD and
   controller tests for policy exclusions, PVC/PV resolution failures, and
   empty selections). Do not add a production test issuer or local policy
   reimplementation.
2. Upgrade the deployed Velero version and verify the status on a real Backup.
3. Add KSM custom-resource metrics for the new status and loader wiring.
4. Replace the historical-count comparison in the Mimir rule only after the
   new selection telemetry is present, retaining a warning for old Backups
   that lack the field during the migration window.

Until step 1 exists, #2884's warning rule is the correct fail-safe: it is
noisy for intentional policy changes but still catches a nonzero partial
capture that the absolute zero-volume rule cannot see.
