# Garage v2.4.0 upgrade — drop Ottawa fork pin

Worktree: `/workspace/worktrees/km/garagepanic`  
Branch: `work/garage240`  
Remote: `https://github.com/keiretsu-labs/kubernetes-manifests.git`  
Date: 2026-09-07 UTC

## Goal

Replace Ottawa’s fork pin  
`ghcr.io/rajsinghtech/garage:v2.3.0-multipart-fix-63a41e9…@sha256:38cccb8a…`  
and the base default `dxflrs/garage:v2.3.0` with **one upstream multi-arch tag**:  
`dxflrs/garage:v2.4.0@sha256:715d176efc35384bf72cf6052fd61b74b3e27a1e31a9dfedabe646bd1e92f137`.

## Why this is safe enough to propose

1. **Empty-block guards are in v2.4.0** (verified earlier against tag raw sources; reconfirmed in `v2.3.0..v2.4.0` history: #1522 merge `845db1af` + both S3 commits).
2. **v2.3.0 → v2.4.0 is a minor upgrade** by Garage’s own rule (first nonzero version component unchanged). From `doc/book/operations/upgrading.md`: minor upgrades keep protocols/data structures compatible; roll nodes one-by-one; no `garage migrate` major path required.
3. **Docker Hub publishes multi-arch `v2.4.0`** (amd64/arm64/arm/386). Index digest pinned above. Ottawa no longer needs an amd64-only fork; Robbinsdale/St. Petersburg can leave stock v2.3.0.
4. **Ottawa is currently healthy** on the fork build (Ready, 0 gateway restarts, no recent panics) — good baseline before rolling.

## Changelog review beyond #1522 (material to us)

From `git log v2.3.0..v2.4.0` (~100 commits). Not a major migration guide (no `migration-24` doc; only historical major guides through migration-2).

| Area | Notable changes | Our impact |
| --- | --- | --- |
| S3 empty-block panics | #1522 | **Why we upgrade** |
| S3 DeleteObjects | non-existent key treated as success (#1469) | Harmless / closer to AWS |
| S3 PostObject UTF-8 form values | #1492 | Harmless |
| CORS / SigV4 whitespace / XSS on web errors | several | Positive hardening; we use S3+web APIs |
| Admin API | layout stats JSON, GetNodeInfo fields, alias listing without perms (#1498/#1435/…) | Operator/WebUI may see richer JSON; OpenAPI schema bump in tree |
| Consul deregister on shutdown | #1507 | **N/A** — we do not use Consul discovery |
| K2V monotonic reads default | #1452 | **N/A** unless something uses K2V; our primary consumers are S3 (Zot, Velero/Kopia, backups, logs) |
| TypedTree internal migration | BlockRc etc. | Internal; no operator `garage migrate` step called out for 2.3→2.4 |
| Helm bind-address values | #1383 | Chart-only; we use garage-operator CR |
| Dependency/Rust bumps | post-2.3.0 | Image rebuild only |

**No evidence of an on-disk metadata format break or required offline migration for 2.3→2.4.** Still treat as a careful rolling upgrade of a shared object store.

## Git changes in this branch (not applied)

1. `kubernetes/apps/base/garage/garage/garagecluster.yaml`  
   - Default image → digest-pinned `dxflrs/garage:v2.4.0@sha256:715d176e…`  
   - `GARAGE_IMAGE` remains overridable for emergencies.
2. `clusters/talos-ottawa/flux/vars/cluster-settings.yaml`  
   - **Remove** `GARAGE_IMAGE` fork override entirely.

Effect after Flux reconcile: **all three clusters** converge on the same upstream digest (Ottawa leaves the fork; RB/SP leave stock v2.3.0).

## Server-side dry-run results (no apply)

| Cluster | Method | Result |
| --- | --- | --- |
| Ottawa | `kubectl apply --dry-run=server` of substituted GarageCluster | **Accepted** (exit 0). Warning only: missing last-applied annotation; federated `deletionPolicy` omitted (pre-existing). Image in dry-run object: `dxflrs/garage:v2.4.0@sha256:715d176e…` |
| Ottawa | `kubectl patch … --dry-run=server` image merge | **Accepted** |
| Robbinsdale | same patch dry-run | **Accepted** |
| St. Petersburg | same patch dry-run | **Accepted** |

Flux will not silently wedge on CRD rejection for this image field change.

## Rollout plan (for humans after merge — not executed here)

1. Merge GitOps only; let Flux update `GarageCluster.spec.image`.
2. Prefer **storage then gateway** (or operator’s natural rollout order); watch one node/pod at a time.
3. Between locations: `GarageCluster` Ready, gateway Ready, sample S3 HEAD/PUT to registry bucket and a Velero/Kopia path, check gateway logs for panic.
4. Confirm `garage_build_info` / pod image ID shows v2.4.0 digest everywhere.
5. Do **not** delete buckets or force repairs as part of this upgrade.

## Rollback plan

1. **Ottawa emergency:** restore  
   `GARAGE_IMAGE: "ghcr.io/rajsinghtech/garage:v2.3.0-multipart-fix-63a41e9bf41e25f27adf83752c8c9a1e6cc3e0b6@sha256:38cccb8a9ef4c20f80c372c9ae4c5cf0ef32596ee00fc5f3ce32355331798847"`  
   in Ottawa `cluster-settings` (exact previous pin).
2. **Base/all clusters:** revert default to  
   `dxflrs/garage:v2.3.0` or re-pin the previous digest if needed.
3. Minor-version rollback is supported by Garage’s upgrade doc (nodes can move between contiguous minor builds without major migrate). Prefer rolling back before declaring metadata corruption; take metadata snapshots if doing a risky window (`garage meta snapshot --all` where available).
4. Keep the fork image tag/digest published until rollback window closes.

## Risks called out honestly

- Shared store for **Zot registry + Velero/Kopia + DB backups + logs** — brief S3 errors during pod restarts are expected; a bad binary would be expensive.
- Federated three-site mesh: stagger by site if operator rollout is simultaneous.
- Admin API JSON schema growth may surprise garage-webadmin if it is schema-strict (watch UI after upgrade; not a blocker for S3).
- Consul panic #1526 exists upstream but is irrelevant without Consul discovery.

## What I refuted

- **“Need a major offline migration for 2.4”** — not supported by Garage upgrade rules or migration docs for this bump.
- **“Keep the fork forever because upstream never shipped the fix”** — refuted; v2.4.0 includes #1522.
- **“Image field change might be CRD-rejected and wedge Flux”** — server-side dry-run on ot/rb/sp accepted the new image.

## Limits honored

- No live apply/restart/repair/bucket delete.
- No merge.
- Digest verified from Docker Hub / registry-1.docker.io content digest.
