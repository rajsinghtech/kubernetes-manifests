# #695 — make StP Home Assistant config recoverable (data fix)

**Status:** recommendation + optional GitOps draft. **Not merged / not applied.**  
Detection already shipped (km#2764). This is the **data** half.

## Current state (evidence, 2026-09-07, read-only)

| Fact | Evidence |
|------|----------|
| PVC `home-assistant/homeassistant-config` | Bound, **10 Gi**, `storageClassName: **local-path**` |
| Underlying PV | **hostPath** `/var/local-path-provisioner/pvc-f3bf0dd8-…_home-assistant_homeassistant-config` on **orin-0** |
| PodVolumeBackups for `homeassistant-0` | **0** (all 7 HA-namespace PVBs are AirConnect `emptyDir` named `config`) |
| Latest schedule backups | Often `Completed` with **warnings=1** (hostPath skip) |
| CSI snapshots | **None** — only SC is `local-path`; no VolumeSnapshotLocation; only CSI driver is secrets-store |
| Live data size | `/config` ≈ **12 MiB** (sqlite + yaml + `.storage`); **no `/config/backups` HA archive directory** |
| Other copies | **None found**: no CronJob, no GarageBucket for HA config, no SMB PV on StP for HA |
| PVC in Git | **Not** in the HA kustomization — cluster-only object (out-of-band create); STS references it |
| Pinning | STS `nodeSelector: kubernetes.io/hostname: orin-0` **and** RWO local-path nodeAffinity → double pin |
| orin-0 headroom | Allocatable ~5.4 Gi; requests **~5014 Mi (~90%)**; HA Guaranteed **1 Gi+32 Mi** |

**Bottom line:** the only copy of Home Assistant’s durable config today is the live hostPath directory on orin-0. Velero “Completed” backups do not contain it. Loss of orin-0 disk = loss of HomeKit/HA state.

Ottawa HA is fine (`ceph-block-replicated`). Robbinsdale has SMB + Ceph patterns. StP has **Garage** (on spark nodes) and SMB credentials in cluster-secrets, but **no csi-driver-smb** installed on StP.

---

## Options priced honestly

### (a) Move off local-path (structurally right; two-for-one with unpin)

**Goal:** PVC Velero can fs-backup (or CSI-snapshot later), schedulable on spark-0/1.

**Arithmetic / constraints**

- HA needs Guaranteed **1032 Mi** + LAN macvlan `192.168.73.140/24` on `eth0`.
- spark-0/1: ~100 Gi+ allocatable, ~6–8 Gi used → **memory fine**.
- orin-0: freeing HA recovers ~1 Gi request headroom on the sole CP (material after #700).
- StP has **no Ceph**. Realistic durable classes:
  1. **CSI SMB** to a NAS (like Robbinsdale) — needs installing `csi-driver-smb` on StP + share path + secret (SMB_* already in cluster-secrets).
  2. **Garage via CSI/S3 gateway** — not a standard RWX filesystem for HA’s sqlite; **unsuitable** as primary `/config` mount (sqlite + WAL on object store is unsafe).
  3. **local-path on a spark node** — still hostPath → **Velero still skips**; only moves the pin, does **not** fix backup.

**Migration procedure (manual; not a Flux one-shot)**

1. Install CSI SMB (or other non-hostPath SC) on StP; create empty PVC.
2. Scale HA to 0; **copy** hostPath → new volume (`tar`/`rsync` via a one-shot pod with both mounts or node access).
3. Point STS at new PVC; remove `nodeSelector: orin-0` (keep CP toleration only if still needed).
4. Ensure Multus `lan` NAD works on spark NICs (`master: eth0` — verify interface name on DGX spark).
5. Bring up; validate HomeKit/mDNS from LAN (phone / `dns-sd`); confirm `192.168.73.140` not held elsewhere.
6. Run Velero backup; confirm **PodVolumeBackup for `homeassistant-0`/`config`**.
7. Only then delete old local-path PV (Retain/Delete policy careful).

**Cost:** hours of careful ops + HomeKit re-pairing risk if IP/MAC changes; macvlan static IP can move with the pod if NAD unchanged, but mDNS/HomeKit is brittle across moves. **Not safely “just GitOps” without a human cutover.**

### (b) Non-Velero copy to Garage (fastest real recoverability)

**Goal:** periodic tarball of `/config` into Garage S3, independent of Velero/hostPath.

**Arithmetic**

- Payload ~12 MiB → trivial for Garage (`velero` bucket is 320 Gi used; dedicated bucket better).
- Job runs **in-cluster next to the pod** (same node) or via `kubectl cp` pattern: best is a CronJob with a **shared volume mount**. That requires either:
  - a sidecar/shared emptyDir sync (complex), or
  - CronJob using the **HA API** / copying via a privileged node-path mount of the known hostPath (couples to path), or
  - **exec + tar stream to S3** from a Job with SA that can `pods/exec` (RBAC) — common and keeps HA running.

Recommended shape: CronJob in `home-assistant` ns, daily, that:

1. `kubectl exec homeassistant-0 -- tar czf - -C /config .` (or use HA’s backup API if enabled later)
2. Uploads to `s3://home-assistant-config/${LOCATION}/…` via Garage gateway
3. Retains N days; alerts on job failure

**Pros:** recoverability **this week**; no HomeKit move; small blast radius.  
**Cons:** still **node-local primary**; orin-0 death loses latest minutes; does not unpin HA from CP.  
**GitOps-able:** yes (Bucket + Key + CronJob + RBAC), after merge.

### (c) Home Assistant built-in backups

Live `/config` has **no `backups/` directory** and no evidence automatic HA Supervisor backups (this is container HA, not HA OS). Enabling HA’s backup integration still needs a **durable destination** (S3/Samba). Without that, backups land on the same hostPath → same failure domain. Treat as a UI nicety **on top of (b)**, not a substitute.

---

## Recommendation

1. **Do (b) now** — Garage tarball CronJob so *some* recoverable copy exists.  
2. **Plan (a) with CSI SMB** (or future Ceph) as the structural fix that also **unpins HA from orin-0** (two-for-one with today’s HomeKit/memory saga).  
3. Keep km#2764 detection; do not trust Velero Completed for this volume until (a) lands.  
4. **Do not** move HA to spark **local-path** — false progress.  
5. **Do not** mount Garage/S3 as `/config` for sqlite.

### Optional GitOps draft in this branch

Under `kubernetes/apps/base/home-assistant/home-assistant/backup/` (commented / not wired into Flux kustomization until approved):

- `GarageBucket` + `GarageKey` for `home-assistant-config`
- CronJob + Role/RoleBinding for exec+upload

Wiring into `app/kustomization.yaml` is intentionally **omitted** so merge alone does not start writing until Raj reviews credentials/RBAC.

---

## Acceptance after (b)

- Object appears in Garage under the HA prefix within one schedule period (or manual Job).  
- Restore drill: fetch tarball → extract to empty dir → diff critical yaml/`home-assistant_v2.db` size.  
- CronJob failure alerts (Job failed / no new object in 36h).

## Acceptance after (a)

- PVC not `local-path` / not hostPath.  
- Pod can run on spark-* without orin-0 selector.  
- Velero PVB for `homeassistant-0`/`config` = Completed.  
- HomeKit/mDNS validated on LAN IP `.140`.
