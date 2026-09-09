# VolSync → Velero Migration Analysis

## Current State

### Scale
- **54 StorageStacks** across 3 clusters (Ottawa: 30, Robbinsdale: 22, StPete: 2)
- All managed via KRO `StorageStack` RGD + Flux GitOps
- Total PVCs under backup: ~54 (mostly small config PVCs)

### PVC Size Profile
| Size Range | Count | Examples |
|---|---|---|
| 5-10Gi | ~45 | Most media/agent/hermes configs |
| 20-50Gi | ~6 | hermes-data, jellyfin-config, plex-config, assistant-raj |
| 100Gi | ~2 | frigate-config-ceph, immich-library (1Ti) |

**Key insight**: ~83% of our PVCs are <10Gi config databases. The 1Ti immich-library is the outlier.

### VolSync Model
- **Per-PVC granularity**: one ReplicationSource per PVC
- **restic backend**: S3 repo per StorageStack prefix
- **Snapshot copy method**: VolumeSnapshot before restic upload
- **Retention**: 1 hourly, 3 daily, 4 weekly, 2 monthly, 1 yearly
- **Schedule**: single daily per PVC (pip install 3-4am cluster for most)
- **Prune**: every 14 days

## What Migration Would Involve

### 1. Data Model Change

| Aspect | VolSync | Velero |
|---|---|---|
| Granularity | Per-PVC (54 ReplicationSources) | Per-namespace (one backup captures all PVCs in ns) |
| Uploader | restic | Kopia (default) |
| Recovery | ReplicationDestination + manual restore | `velero restore create` |
| PVC dependencies | Per-PVC, independent | Namespace-level, captures all resources together |
| Schedule | Per-StorageStack (cron field) | Per-Velero schedule object |
| Retention | Per-StorageStack (7-tier) | Per-backup TTL (global default) |

### 2. Migration Steps

**Phase 1: Deploy Velero (DONE ✓)**
- Velero + Kopia running on all 3 clusters
- BSL pointing to Garage
- Schedules for media, hermes, agents, immich, home

**Phase 2: Run Velero + VolSync in parallel (recommended — 1-2 weeks)**
- Both tools run their scheduled backups simultaneously
- VolSync remains the primary restore target
- Velero builds up a complete Kopia snapshot history
- After 1-2 weeks, verify Velero can restore PVCs correctly

**Phase 3: Cutover**
- Once proven, disable VolSync per-namespace:
  - Set `backupPaused: true` on StorageStacks (KRO will pause ReplicationSources)
  - OR delete StorageStack instances (which tears down ReplicationSources + VolSync restic repos)
- VolSync namespace stays up (don't uninstall it — preserves ReplicationDestination CRDs for restores)
- Velero schedules are already running

**Phase 4: Cleanup (optional)**
- Remove GarageKey permissions for VolSync keys
- Purge old VolSync restic repos from Garage
- Uninstall VolSync from clusters

### 3. What Needs to Change Per-Cluster

**Per namespace being migrated:**
- Velero already has schedules for `media`, `hermes`, `agents`, `immich`, `home`
- For each namespace, when confident, pause VolSync backups

**StorageStack changes:**
- Set `backupPaused: true` per StorageStack
- OR remove the StorageStack entirely
- Retain ReplicationDestinations for restore capability

### 4. Risks & Considerations

**Data consistency during migration:**
- VolSync uses VolumeSnapshot before upload (consistent point-in-time)
- Velero Kopia uses FSB (file-level, no guarantee of crash consistency unless app quiesced)
- For databases (postgres, immich), both may capture in-flight writes

**immich-library (1Ti):**
- First Kopia backup will be a full scan — will take hours
- Velero's node-agent default CPU/memory may be tight for this
- May need node-agent resource bumps for immich namespace

**VolSync ReplicationDestinations (clusters/ha):**
- Robbinsdale has frigate-config-ceph-dest + homeassistant-config-ceph-dest (cross-cluster replicas)
- Velero doesn't have a cross-cluster replication model
- Would need separate Velero instance per cluster (already done) + manual restore for cross-cluster

**Scheduling:**
- Currently VolSync staggers PVCs at different times (3am-6am)
- Velero schedules are per-namespace, running sequentially within namespace
- This could cause more I/O contention during backup windows

**restic repo cleanup:**
- Old restic repos in Garage (under `agents/*`, `media/*`, `hermes/*`, `home/*`, `immich/*`)
- ~54 repos, some with data dating back months
- Should NOT delete until migration is stable (safety net)

### 5. Migration Map

| Namespace | Cluster | StorageStacks | Current Schedule | Velero Schedule |
|---|---|---|---|---|
| media | ottawa | 20 | 0 4 * * * | 0 7 * * * ✓ |
| media | robbinsdale | ~20 | 0 4 * * * | 0 7 * * * ✓ |
| hermes | ottawa | 1 | 0 4 * * * | 0 7 * * * ✓ |
| agents | ottawa | 5 | 0 4 * * * | 0 7 * * * ✓ (in hermes schedule) |
| immich | ottawa | 1 | 0 3 * * * | 0 8 * * * ✓ |
| home | robbinsdale | 2 | 0 5-12 * * * | 0 9 * * * ✓ |
| home-assistant | stpete | 2 | 0 12 * * * | — needs adding |
| immich | robbinsdale | (present) | — | — Velero schedule covers ✓ |

### 6. Estimated Timeline

| Phase | Duration | Effort |
|---|---|---|
| Phase 1 (deploy Velero) | ✅ Done | ✅ Done |
| Phase 2 (parallel run) | 1-2 weeks | Monitoring only |
| Phase 3 (cutover per-ns) | 1 day | Set backupPaused:true on 54 StorageStacks |
| Phase 4 (cleanup) | 1 day | Optional — restic purge + VolSync uninstall |
