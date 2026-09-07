# #695 — StP HA capture via kopiur (Direct)

**Status:** merged via km#2775; apply fix for mover scheduling on `work/kopiur-mover-schedule`.  
VolSync is out (Raj). Velero FSB still skips hostPath; leave `home-assistant-backup` + km#2764 alone.

## Constraints encoded in manifests

| # | Constraint | Where |
|---|------------|--------|
| 1 | `copyMethod: Direct` **explicit** | `SnapshotPolicy` |
| 2 | Source `readOnly: true` | `SnapshotPolicy.sources[]` |
| 3 | Dedicated bucket `kopiur-stpetersburg` + own Kopia password | GarageBucket + ESO Password |
| 4 | `maintenance.enabled: false` (km#2767 RAW) | `Repository` |
| 5 | Chart `0.10.7` + image digests pinned | `HelmRelease` |
| 6 | StP only | `kubernetes/apps/stpetersburg/kopiur` |

## Apply fix (invalid `SnapshotPolicy.spec.mover.tolerations`)

Installed CRD: `spec.mover` allows only `cache`, `inheritSecurityContextFrom`,
`podSecurityContext`, `privilegedMode`, `resources`, `securityContext`,
`ttlSecondsAfterFinished` — **no tolerations**.

How Direct movers still schedule onto tainted orin-0:

1. **Not** HelmRelease root `tolerations` — chart model: root = controller only.
2. **Not** `inheritSecurityContextFrom` — security only; HA also pins no `runAsUser`.
3. **Yes:** `Repository.moverDefaults.sourceColocation: Auto` (default) pins the
   mover to the RWO holder node and **unions the holder pod's tolerations**.
   `homeassistant-0` already has `node-role.kubernetes.io/control-plane` Exists
   NoSchedule.
4. **Yes:** `Repository.moverDefaults.tolerations` (CRD-valid) as explicit base.

Root read access: `securityContext.runAsUser: 0` + `runAsNonRoot: false` **and**
`privilegedMode: true` (namespace-gated; preserve ownership on restore). Mount
stays `readOnly: true`.

## Acceptance (do not claim success without)

1. A `Snapshot` for `homeassistant-config` reaches **Succeeded** with **non-zero** `status.stats.files*` (zero files = UID mismatch false success).
2. `Restore` into a **new empty PVC**; byte-compare critical paths (`configuration.yaml`, `home-assistant_v2.db`, `.storage/`) against source.

“Schedule exists” is **not** acceptance.

## License

kopiur is **AGPL-3.0-only**.
