# #695 — StP HA capture via kopiur (Direct)

**Status:** GitOps draft on `work/kopiur-stp-ha`. **Not merged / not applied.**  
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

Root mover + `privileged-movers` annotation: live `/config` has root-owned `0600` files; mount stays read-only.

## Acceptance (do not claim success without)

1. A `Snapshot` for `homeassistant-config` reaches **Succeeded** with **non-zero** `status.stats.files*` (zero files = UID mismatch false success).
2. `Restore` into a **new empty PVC**; byte-compare critical paths (`configuration.yaml`, `home-assistant_v2.db`, `.storage/`) against source.

“Schedule exists” is **not** acceptance.

## License

kopiur is **AGPL-3.0-only**.
