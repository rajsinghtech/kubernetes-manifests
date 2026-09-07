# km#2753 post-merge verification — INEFFECTIVE; corrected root cause

Date: 2026-09-07 UTC  
Worktree: `/workspace/worktrees/km/garagepanic` branch `work/referrers2`  
Remote: `https://github.com/keiretsu-labs/kubernetes-manifests.git`

## Verdict

**km#2753 merged and rolled out, but it did not fix `/referrers/` latency.** Treating it as done would be false. This note supersedes the optimism in `referrers-FINDINGS.md` / the #2753 merge claim.

## Post-merge evidence (all after Flux applied `6d3bd2914`)

| Check | Result |
| --- | --- |
| Live `cm/zot-config` | `extensions.sync.enable=true`, one registry `ghcr.io` / `rajsinghtech/**`, **`onDemand: false`** |
| Pods | `zot-74698dc659-*` age ~4–5m at first measure; config checksum rolled |
| Startup log | `OnDemand:false`, `PollInterval:6h`, `sync extension is enabled` |
| Still logged | `trying to get updated referrers by syncing on demand` for `corp/bhaiya` |
| Still logged | `trying to get updated image by syncing on demand` for `corp/workspace` / `0.3.277` |
| Referrers latency | still **~14s** when it completes; also **28s** and **http=000 at 30–45s** under load — **not better** |
| GraphQL `Referrers` (MetaDB) | **~40–80ms**, empty list |
| ImageList MetaDB | `corp/bhaiya` **697** images; `corp/workspace` **151** |
| Scheduled poll | `SyncGenerator` repeatedly **`failed to list repositories for ghcr.io: unauthorized`** — poll was already non-functional without credentials |

Comparable method to pre-fix: digest from `manifests/latest`, curl matrix with max-time 3/5/12/15/20(+). Pre-fix: ≤12s hang, ≥15s → 200 in ~14s. Post-#2753: same pattern; sometimes worse.

## Why `onDemand: false` cannot stop the gate (source, zot v2.1.20)

Raj’s hypothesis is **correct**:

1. `getReferrers` / missing-manifest paths call `isSyncOnDemandEnabled(ctlr)` (`pkg/api/routes.go`).
2. That returns true when **`extensions.sync.enable` and `ctlr.SyncOnDemand != nil`** — **not** when any registry has `OnDemand: true`.
3. `EnableSyncExtension` **always** `NewOnDemand(log)` when sync is enabled, then only `onDemand.Add(service)` for registries with `OnDemand: true` (`pkg/extensions/extension_sync.go`).
4. With only periodical sync (`pollInterval` set, `onDemand: false`): **no services are Added**, but a **non-nil empty** `BaseOnDemand` is still returned and assigned to `Controller.SyncOnDemand`.
5. Result: every `/referrers/` still logs “syncing on demand”, awaits `SyncReferrers` (empty loop, returns quickly), then runs storage `GetReferrers`.

So #2753 removed the filtered SyncReferrers **service work** (no more “filtered out by sync config” on that path) but **did not disable the gate**.

## Where the ~14s actually goes

After the empty SyncReferrers return, `imgStore.GetReferrers` (`pkg/storage/common/common.go`) does:

- load the repo index
- for **every** descriptor, `GetBlobContent` (S3/Garage) and JSON-parse to see if `subject` matches

With ~697 images in `corp/bhaiya`, that is an **O(n) S3 read** per referrers query. That matches:

- GraphQL Referrers (MetaDB index) ~50ms vs OCI `/referrers/` ~14s+
- tags/list and large catalog endpoints also becoming slow under the same storage pressure
- v2.1.21 still uses the same storage `GetReferrers` + same sync gate (no MetaDB fast path for the OCI route). `manifestCheckInterval` (#4328) only throttles upstream on-demand checks; it does not replace the S3 scan.

**#2753 could never make OCI `/referrers/` fast on this repo size.** At best it removed a small sync-service overhead on top of the scan.

## Does the release path get faster?

**No measurable win expected from #2753 for current `corp/bhaiya` validate.**

- `.woodpecker/release.sh` on main **does not call `/referrers/`** (provenance is manifest/config labels).
- Manifest GETs for local `corp/*` still hit `getImageManifest`’s “syncing on demand” log while sync stays enabled (empty SyncImage), and we still saw **5–11s** on `corp/workspace:0.3.277` under load — that is a separate on-demand **gate**, not the S3 referrers scan.

## Poll sync after disabling onDemand

We said poll would remain. Live: **`SyncGenerator` fails unauthorized against ghcr.io** repeatedly since restart. So the “keep poll” benefit is currently **aspirational** unless credentials are added. Disabling the whole sync extension would not remove a working mirror that we are successfully using right now; it would remove a failing generator and the SyncOnDemand gate.

## Options that can actually work

| Option | Effect on gate log / empty Sync* | Effect on ~14s `/referrers/` | Cost |
| --- | --- | --- | --- |
| A. Keep #2753 only | Partial (no SyncReferrers service) | **None** | Already merged; **do not claim fixed** |
| B. `"sync": { "enable": false }` | Stops gate (`SyncOnDemand` nil) and on-demand manifest waits | **None** (S3 scan remains) | Loses broken/unauth poll; fine if we don’t rely on ghcr pull-through |
| C. Client timeouts ≥20–30s for OCI referrers | N/A | Makes hang look like success when scan finishes | Does not fix server cost; current release.sh doesn’t need it |
| D. Upstream: MetaDB-backed OCI GetReferrers (or index) | N/A | **Real fix** | Needs upstream work; not in v2.1.21 |
| E. Shrink `corp/bhaiya` retention / split repos | N/A | Reduces O(n) | Operational, not a sync flag |

**Honest recommendation:**  

1. **Do not close the referrers problem on #2753.**  
2. Prefer **B** if Raj agrees ghcr sync isn’t earning its keep (evidence: unauthorized poll). That stops misleading on-demand waits on local repos.  
3. Accept that **OCI `/referrers/` stays slow** until D or E; use GraphQL/search for any internal referrer queries.  
4. **Do not** raise release timeouts as the primary “fix” for validate wedges that aren’t calling `/referrers/`.

## #527 overall (three-problem split)

| Problem | Status |
| --- | --- |
| 1. Write-path multipart panic | Mitigated in Ottawa (fork pin); fixed upstream in **v2.4.0** (#1522). Upgrade PR #2751 still awaiting sign-off to drop the fork. |
| 2. Read-path `get.rs` empty-block panic | Same as (1). |
| 3. Referrers / validate latency story | **Not fixed.** #2753 ineffective for latency; real cost is S3 `GetReferrers` scan (+ sync gate still active). |

**Do not close #527** until (3) is honestly dispositioned (B+documented residual, or upstream/timeout plan) and Raj is happy with (1)(2) via v2.4.0 or the fork remaining.

## What I refuted

- **“#2753 fixed referrers in prod”** — refuted by live latency + logs.  
- **“Per-registry `onDemand: false` disables SyncOnDemand”** — refuted by `EnableSyncExtension` + `isSyncOnDemandEnabled`.  
- **“Remaining ~14s is still SyncReferrers filtering”** — refuted; filtered-out lines are gone; MetaDB GraphQL is fast; storage `GetReferrers` is O(n) S3.  
- **“Release validate will get faster from #2753”** — not supported; release.sh doesn’t use `/referrers/`.  
- **“Poll sync still works after #2753”** — poll generator is failing unauthorized.

## Limits

- Read-only verification; no further live apply in this turn until Raj picks B/C/D/E.  
- Findings only; honesty over a second hopeful merge.
