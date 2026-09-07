# #695 — make StP Home Assistant config recoverable (data fix)

**Status:** verification + recommendation. **Not merged / not applied.**  
Detection already shipped (km#2764). This is the **data** half.  
**STOP (Raj):** do **not** ship a Garage tarball CronJob from this PR.

## Current state (evidence, 2026-09-07, read-only)

| Fact | Evidence |
|------|----------|
| PVC `home-assistant/homeassistant-config` | Bound, **10 Gi**, `storageClassName: **local-path**` |
| Underlying PV | **hostPath** on **orin-0** (`/var/local-path-provisioner/pvc-f3bf0dd8-…`); createTime **2026-07-03** |
| PodVolumeBackups for `homeassistant-0` | **0** (ns PVBs are AirConnect `emptyDir` named `config` only) |
| Latest Velero backup | `home-assistant-backup-20260906090023` **Completed**, **warnings=1** |
| Velero skip reason (log) | `Volume config in pod home-assistant/homeassistant-0 is a hostPath volume which is not supported for pod volume backup, skipping` |
| Live data size | `/config` ≈ **12 MiB**; no `/config/backups` HA archives |
| Off-node copy today | **None** |

**Bottom line:** live hostPath on orin-0 is the only copy. Velero “Completed” does not contain `/config`.

### Historical VolSync / restic (verified)

| Fact | Evidence |
|------|----------|
| Pre-#1666 StorageStack | Daily `0 12 * * *`, `copyMethod: Direct`, `s3Path: home-assistant/config`, bucket alias **`keiretsu`**, repo `…/keiretsu/stpetersburg/home-assistant/config` |
| VolSync removed | `5e368b6fc` (2026-06-13) — claimed Velero would replace all StorageStacks |
| Restic corpus deleted | `9bba495a2` (2026-06-16) — **“Purged all 490 GiB of S3/restic contents”**; removed `keiretsu` GarageBucket/Key |
| Live Garage | `GetBucketInfo?globalAlias=keiretsu` → **NoSuchBucket** on OT, RB, and SP admin APIs |
| StP restic secret | Gone. OT/RB orphan `restic-*` secrets still point at deleted `keiretsu` paths |

**Conclusion:** even if VolSync completed before Jun 13, those snapshots are **gone**. The Jul 3 PVC is post-purge and was never covered by restic.

### Sister rows (brief)

| Row | Velero volume capture |
|-----|----------------------|
| Ottawa / Robbinsdale HA | **OK** — daily PVB ~7 MiB Completed on Ceph/SMB |
| StP HA | **Skipped** — hostPath |
| Immich OT/RB | **No Velero schedule** (library on Ceph/SMB; `immich-postgres` Garage bucket exists for DB only). `#1664` promised `immutable-backup` — not present |
| Hermes OT | Schedule Completed but Deployment **0/0** → **0 PVBs** (PVC Bound, unused) |

---

## Options priced honestly

### (a) Move off local-path (structurally right; unpins orin-0)

**Goal:** non-hostPath PVC so Velero FSB works (as on OT/RB), pod schedulable on spark-0/1.

StP has **no Ceph**. Realistic class: **CSI SMB** (creds exist; **csi-driver-smb not installed** on StP).  
**Not** spark local-path (still hostPath → Velero still skips).  
**Not** S3/Garage as `/config` (sqlite unsafe).

**Cost:** human cutover (scale 0 → copy → retarget STS → HomeKit/mDNS validation on `.140`). Not a Flux one-shot.

### (b) VolSync Direct **only** for this local-path PVC (narrow reintro)

Historically **1 of 54** StorageStacks used `local-path` (this one). Fleet VolSync is unnecessary.

| Piece | Cost |
|-------|------|
| VolSync operator on **StP only** | Chart ~0.16.x; requests ~100m/64Mi |
| One `ReplicationSource` | `copyMethod: Direct` (no VolumeSnapshotClass on local-path) |
| New Garage bucket + key | Do **not** recreate `keiretsu`; new alias |
| Data | ~12 MiB |

**Pros:** GitOps-able; actually reads hostPath (unlike Velero).  
**Cons:** keeps HA pinned to orin-0; reintroduces an operator for one PVC; mover I/O on CP node.

### (c) HA built-in backups

No archives on disk today. Still needs a durable destination outside hostPath. Not sufficient alone.

### ~~Garage tarball CronJob~~ — **stopped**

Explicitly out of scope for this PR per Raj STOP.

---

## Recommendation

1. **Accept historical restic as unrecoverable** (`keiretsu` purged). No S3 archaeology left.  
2. **Choose near-term protect:**  
   - **(b) VolSync Direct + new bucket** if the priority is “something restorable this week” without moving HomeKit; **or**  
   - **(a) CSI SMB migrate** if willing to spend a cutover window (preferred end state; also unpins CP).  
3. Keep km#2764 detection; do not trust Velero Completed for this volume until (a) lands.  
4. Follow-ups (not #695 blockers): Immich Velero/NAS policy; Hermes scaled-to-zero backup policy; delete orphan `restic-*` secrets.

## Acceptance

**After (b):** ReplicationSource `lastSyncTime` advances; `restic snapshots` (or VolSync status) shows inventory in the **new** bucket; restore drill to empty PVC.  
**After (a):** PVC not hostPath; Velero PVB for `homeassistant-0`/`config` Completed; HomeKit/mDNS OK on `.140`; orin-0 selector removed.
