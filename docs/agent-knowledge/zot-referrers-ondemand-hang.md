# Registry `/v2/.../referrers/` hang — root cause and fix

Date: 2026-09-07 UTC

## Where the fix belongs

**kubernetes-manifests (Zot config), not corp/bhaiya CI.**

Current `.woodpecker/release.sh` on `corp/bhaiya` **does not call `/referrers/`**
(`git grep referrers` empty). Provenance today is config-label / manifest /
blob based with bounded `curl --max-time`. The old agent note that blamed
`release.sh` for querying referrers is **stale** (also corrected in
`check-the-signal-discriminates.md`: “the script never queries it”).

The endpoint is still broken for **any** client that does (cosign, oras, crane
referrers, browsers, future CI). Fixing Zot removes the hang class entirely.

Worktree/branch: `/workspace/worktrees/km/garagepanic` → `work/referrers`  
Remote: `https://github.com/keiretsu-labs/kubernetes-manifests.git`

## What actually hangs

Not “forever with no timeout.” Measured against
`https://oci.cdn.keiretsu.top/v2/corp/bhaiya/referrers/<digest>`:

| Client max-time | Observed |
| --- | --- |
| 3s / 5s / 8s / 12s | `curl (28)` timeout, **0 bytes**, http=000 |
| 15s / 20s / 30s | **HTTP 200** after **~14.0–14.4s**, body `{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}` |

Same registry: `tags/list` ~0.13s, `manifests/latest` ~0.09s.

So clients with ≤12s budgets correctly report a hang; the server eventually
answers an **empty referrers index**.

## Why Zot is slow (server logs)

On each probe, `zot` logs:

1. `GetReferrers` / `getting manifest`
2. `trying to get updated referrers by syncing on demand`
3. `will not sync reference for image, filtered out by content` (`remote=ghcr.io`, repo `corp/bhaiya` outside `rajsinghtech/**`)
4. `failed to sync image referrers` / `image is filtered out by sync config`
5. HTTP API line: path `/v2/corp/bhaiya/referrers/...` **statusCode=200 latency=13s**

Source (`zot` v2.1.20 `pkg/api/routes.go` `getReferrers`): if sync on-demand is
enabled, **every** referrers request awaits `SyncOnDemand.SyncReferrers` before
`imgStore.GetReferrers`. That wait uses a **detached context with the sync
service timeout** and does not abort when the HTTP client gives up — converting
one filtered no-op into a multi-second blocked response (and pile-up under
retries).

Live sync config (before fix): `onDemand: true`, `pollInterval: 6h`, content
prefix only `rajsinghtech/**`. Local `corp/*` pushes never match; on-demand is
pure latency.

## Relation to #527 / delivery wedges

Three separate problems remain:

1. Garage multipart write panic — mitigated/fixed elsewhere  
2. Garage GET empty-block panic — mitigated/fixed elsewhere  
3. **This referrers latency** — Zot sync-on-demand  

Historical “validate failed provenance / refusing to republish” wedges mixed
(a) real missing immutable tags after a half-publish with (b) timeouts on slow
registry paths. Do not treat (3) as proof that current `release.sh` still hits
`/referrers/`. Do fix (3) so any referrers client stops wedging queues.

## Proposed change (in this branch, not applied)

`kubernetes/apps/base/zot/zot/helmrelease.yaml`:

- set sync registry `"onDemand": false`
- keep `"enable": true` and `"pollInterval": "6h"` so `rajsinghtech/**` still
  refreshes on schedule
- document why in a Helm values comment above `configFiles`

### Expected effect after Flux rolls Zot

`/referrers/{digest}` for local repos should return the empty index from
storage **without** the on-demand sync wait (target: same order of magnitude as
manifest GET, not ~14s).

### Tradeoff

First pull of a **missing** `rajsinghtech/**` image will no longer sync from
ghcr.io mid-request; it waits for poll or an explicit sync. Acceptable: that
prefix is a mirror convenience, not the corp publish path. Corp publishes are
local S3-backed and never needed on-demand ghcr sync.

## Validation performed

- Live curl matrix above + Zot pod logs during probes  
- `config.json` still parses after edit (`onDemand=false`)  
- `tools/check.sh talos-ottawa` → `✓ render OK`  
- `kubectl apply --dry-run=server` of HelmRelease with updated configFiles →
  **accepted**  
- `kubectl patch --dry-run=server` merge of configFiles → **accepted**,
  `onDemand: false` present in dry-run output  

No cluster apply. No Garage repair. No bucket deletes.

## Rollback

Revert `onDemand` to `true` in the same HelmRelease (or restore previous
commit). Poll sync alone does not depend on on-demand.

## What I refuted

- **“release.sh currently queries /referrers/”** — false on today’s main.  
- **“Endpoint hangs forever / never responds”** — false; ~14s then 200 empty
  index. Short client timeouts made it look infinite.  
- **“Fix belongs only in bhaiya CI timeouts”** — insufficient; server still
  burns ~14s and can stall longer under load. Disable the useless on-demand
  wait.  
- **“Disable provenance verification”** — refused; unrelated and unsafe.

## Limits honored

- No live apply/merge.  
- kubernetes-manifests remote confirmed.  
- Findings also under `/workspace/agent-briefs/out/referrers-FINDINGS.md`.
