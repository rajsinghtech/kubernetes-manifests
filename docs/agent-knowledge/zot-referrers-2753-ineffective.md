# km#2753 post-merge — INEFFECTIVE; widened to manifest GETs

Date: 2026-09-07 UTC (updated with manifest-path evidence)  
Branch: `work/referrers2` @ `7adbcf93f`  
Remote: `https://github.com/keiretsu-labs/kubernetes-manifests.git`

## Status of #2753

**Merged, applied, pods rolled — did not fix latency.** Claiming otherwise is worse than the original bug.

| Signal | Post-#2753 |
| --- | --- |
| Live config | `sync.enable=true`, one registry `ghcr.io`/`rajsinghtech/**`, **`onDemand:false`** |
| Still logged | `trying to get updated referrers by syncing on demand` (`corp/bhaiya`) |
| **NEW / critical** | `trying to get updated image by syncing on demand` for **`corp/workspace` `0.3.277`** and other **local corp/* tag** GETs |
| OCI `/referrers/` | still ~14s (also 28s / http=000 at 30–45s) |
| GraphQL MetaDB `Referrers` | ~40–80ms |
| Poll sync | `SyncGenerator` → `ghcr.io: unauthorized` (dead) |

## Source: both paths share one gate (zot v2.1.20)

### Gate (not per-registry `OnDemand`)

```go
// pkg/api/routes.go
func isSyncOnDemandEnabled(ctlr *Controller) bool {
  extensionsConfig := ctlr.Config.CopyExtensionsConfig()
  if extensionsConfig.IsSyncEnabled() &&
     fmt.Sprintf("%v", ctlr.SyncOnDemand) != fmt.Sprintf("%v", nil) {
    return true
  }
  return false
}
```

`EnableSyncExtension` **always** `NewOnDemand(log)` when sync is enabled; it only `Add(service)` for registries with `OnDemand:true`. With only poll sync (`onDemand:false` + `pollInterval`), **no services are added**, but a **non-nil empty** `BaseOnDemand` is still installed → gate stays true forever.

**Config cannot “evaluate content filter before sync” to skip the wait:** filtering happens *inside* `SyncImage`/`SyncReferrers` after the HTTP handler has already decided to await them. There is no registry content entry that short-circuits `isSyncOnDemandEnabled`. An explicit `corp/**` content prefix would only make zot try to sync corp from ghcr (nonsense), not skip the gate.

### `getReferrers` (always waits if gate on)

Always: log → `SyncOnDemand.SyncReferrers` → `imgStore.GetReferrers` (O(n) S3 scan of every repo descriptor; ~697 images in `corp/bhaiya` ⇒ ~14s). Empty SyncReferrers (no services) is cheap; **the scan is the cost**.

### `getImageManifest` (delivery path — Raj’s new evidence)

```go
// Digest reference: return local hit WITHOUT sync; sync only if miss && gate.
content, digest, mediaType, err := imgStore.GetImageManifest(name, reference)
if err == nil || !syncEnabled { return ... }

// Tag reference OR digest miss with sync enabled:
// ALWAYS logs and awaits SyncImage BEFORE re-reading local — even on a local hit.
log "trying to get updated image by syncing on demand"
SyncOnDemand.SyncImage(...)
return imgStore.GetImageManifest(...)
```

So for **tags** (including `corp/workspace:0.3.277`, `latest`, `sha-*` tags that aren’t digests), sync-enabled zot **always** pays the on-demand wait on every GET, even when the image is local and the ghcr filter can never match `corp/*`. Measured: workspace manifest **5–11s** with that log line; digest GETs of a present manifest stay fast (~0.1s) when they hit the digest short-circuit.

That is why #2753’s per-registry flag looked plausible but could not help either referrers or tagged manifest GETs.

## Is ghcr sync load-bearing?

**No evidence it is.** Cluster workloads pull `ghcr.io/rajsinghtech/...` **directly** (garage-operator, tsdnsproxy, tsflow, tsk9s, patched garage image, etc.). Corp images use `oci.cdn.../corp/...`. Live poll sync is **unauthorized** against ghcr without credentials. Keeping `sync.enable=true` currently buys: failing SyncGenerator spam + SyncOnDemand gate on local traffic.

Therefore **disabling the sync extension entirely is the correct config fix** for the gate (already pushed on `work/referrers2`), not “add a corp/** content trick.”

## What disabling sync fixes vs what it does not

| Symptom | After `sync.enable: false` |
| --- | --- |
| “syncing on demand” logs on corp/* | **Gone** (`SyncOnDemand` nil) |
| Empty SyncImage wait on tag GETs | **Gone** |
| Poll SyncGenerator unauthorized errors | **Gone** |
| OCI `/referrers/` ~14s | **Remains** — storage `GetReferrers` O(n) over S3 |
| GraphQL Referrers | Already fast (MetaDB) |

Real OCI `/referrers/` speed needs **upstream MetaDB-backed GetReferrers** (not in v2.1.20/21) or a much smaller repo. Client timeout mitigation does not fix S3 scan cost.

## Client timeout mitigation (if we must keep OCI referrers callers)

Current `release.sh` **does not** call `/referrers/` — validate wedges from that era are not fixed by referrers timeouts alone.

If something else still probes OCI referrers (cosign/oras/crane):

| Client | Suggested budget | Rationale |
| --- | --- | --- |
| Interactive curl / scripts | **≥20s** `max-time` (prefer **30s**) | Empty index often returns ~14s; under load 28s+ seen |
| Parallel CI probes | fail-fast on first transport timeout; **do not** retry into a void | Retries amplify queueing |
| Prefer | GraphQL `/v2/_zot/ext/search` `Referrers` | ~50ms when search/MetaDB enabled |

For **tagged manifest** GETs while sync remains enabled: any client assuming &lt;2s local registry latency can flake; after sync.disable, local tag GETs should return to normal storage latency (still not a substitute for fixing `/referrers/` scan).

## Follow-up already on branch (not claiming prod-fixed until merged+remeasured)

`work/referrers2`: `extensions.sync.enable: false`, docs that #2753 missed the gate, dry-run accepted, render OK.

**Required after merge:** re-run the same curl matrix + confirm logs no longer contain “syncing on demand”; separately note `/referrers/` may still be ~14s.

## #527 close assessment

| # | Problem | Close? |
| --- | --- | --- |
| 1 | Multipart write panic | Mitigated (Ottawa fork) + upstream v2.4.0; upgrade #2751 pending |
| 2 | GET empty-block panic | Same |
| 3 | Referrers / on-demand delivery drag | **Open** — #2753 ineffective; `referrers2` addresses gate only |

**Do not close #527** until Raj merges/verifies sync.disable and accepts residual `/referrers/` O(n) (or an upstream plan).

## What I refuted

- **“#2753 fixed it”** — false in prod.  
- **“Only referrers are affected”** — false; tag manifest GETs on the delivery path hit the same gate.  
- **“Content-filter-first config can skip sync”** — not available in v2.1.20; filter runs inside Sync*.  
- **“Must keep sync for ghcr mirroring”** — not load-bearing here; poll unauthorized; images pull ghcr directly.  
- **“Disable sync makes `/referrers/` fast”** — false; only removes the gate.

## Limits

Honesty over a second false “fixed.” No prod apply from this note beyond what’s already in `work/referrers2` awaiting review.
