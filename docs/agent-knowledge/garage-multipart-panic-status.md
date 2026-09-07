# #527 Garage multipart panic vs delivery blockers — current status

Worktree: `/workspace/worktrees/km/garagepanic`  
Branch: `work/garagepanic`  
Remote confirmed: `https://github.com/keiretsu-labs/kubernetes-manifests.git`  
Date: 2026-09-07 UTC

## Three distinct problems (do not conflate)

| # | Problem | Layer | Status now |
| --- | --- | --- | --- |
| 1 | **Write-path panic** `multipart.rs` CompleteMultipartUpload empty `final_version.blocks` (`[0]` OOB) | Garage S3 gateway | **Mitigated in Ottawa** by patched image; **fixed upstream** in `main-v2` / **v2.4.0** via #1522 |
| 2 | **Read-path panic** `get.rs` `body_from_blocks_range` empty `all_blocks[0]` | Garage S3 GET | Same patched Ottawa image + same upstream #1522 / v2.4.0. **Not the same stack frame** as (1); explains less of the original write-degradation story |
| 3 | **Hanging registry `/v2/.../referrers/`** → provenance/`validate` wedge | Zot/registry client path | **Separate** from Garage panics. One failed publish can block later pipelines at `validate` with misleading messages (`t-gop367.md`). Not fixed by Garage patches |

Issue #527 was opened for (1) as a **probable** cause of Zot write degradation / promote timeouts. That causal link was never request-traced; keep that caveat.

## Live Ottawa evidence (read-only, no repairs)

- `GarageCluster/garage`: Ready, phase Running.
- Image in live CR / pods:  
  `ghcr.io/rajsinghtech/garage:v2.3.0-multipart-fix-63a41e9bf41e25f27adf83752c8c9a1e6cc3e0b6@sha256:38cccb8a9ef4c20f80c372c9ae4c5cf0ef32596ee00fc5f3ce32355331798847`
- Gateways `garage-gateway-0-0` / `garage-gateway-1-0`: Ready, **restartCount 0**, age **~2d19h**.
- 48h gateway logs: **no** `PANIC` / `index out of bounds` / multipart empty-block lines found.
- GitOps: Ottawa-only override in  
  `clusters/talos-ottawa/flux/vars/cluster-settings.yaml` (`GARAGE_IMAGE=…multipart-fix-63a41e9…`).  
  Base default remains `${GARAGE_IMAGE:=dxflrs/garage:v2.3.0}` for other clusters.
- History: `#2682` multipart guard → `#2687` added GET guard on the same Ottawa build.

**Conclusion:** the #527 panic class is **not currently firing** on Ottawa under the patched build. Zero restarts alone would be weak (pods were recreated onto the patch); clean multi-day logs + known guards + upstream merge strengthen recovery.

## Upstream status (branch `main-v2`, not `main`)

- Default branch is **`main-v2`**.
- Issue [#1521](https://git.deuxfleurs.fr/Deuxfleurs/garage/issues/1521) (multipart empty blocks) is **Closed**.
- PR [#1522](https://git.deuxfleurs.fr/Deuxfleurs/garage/pulls/1522) merged to `main-v2`:  
  `api/s3: don't panic when a version has no blocks` — guards **both** completion (`.first()` + internal error) and GET capacity sizing (`.first().map_or(1024, …)`).
- Tag **`v2.4.0`** contains both guards (verified on tag raw sources). Docker Hub `dxflrs/garage` publishes `v2.4.0`.
- Stock `v2.3.0` remains vulnerable; that is why Ottawa still pins a fork digest rather than plain `dxflrs/garage:v2.3.0`.

### AI contribution policy (checked before any upstream patch proposal)

From `CONTRIBUTING.md` on `main-v2` (“Policy on AI”):

- AI **must not** write documentation.
- **Do not** use AI for bug reports, commit descriptions, or PR messages.
- **Do not** use AI agents to make contributions; contributions must be human-led.
- AI **may** only do very mechanical boilerplate/API translations with no copyrightable originality.
- Private AI exploration of the codebase is allowed; **do not** paste LLM output into code or the tracker, and **do not** let an agent edit the codebase directly.

**Implication:** do **not** open or “improve” upstream Garage patches via an agent. The needed guards are already merged. Any follow-up upstream work must be human-authored under that policy. Our remaining GitOps work (image pin / upgrade) is fine in this repo.

## What #527 does *not* explain / no longer blocks

- Earlier agent notes already showed promote succeeding again for later tags while canary/adoption failed for other reasons (`findings-garage527.md`: 0.3.258 adopted; 0.3.259 promote OK, canary failed).
- **Referrers hang** remains a distinct registry-client delivery wedge; fixing Garage panics does not clear a stuck `validate` on `/referrers/`.
- Raising the 650s promote budget remains a **non-fix** for a panicking gateway and should stay rejected as the primary answer.

## Recommended next actions (no live repair performed)

1. **Keep Ottawa on the patched digest** until an intentional upgrade.
2. **Plan (do not execute here) an upgrade to `dxflrs/garage:v2.4.0`** (or later) once operator accepts a coordinated Garage rollout — preferably all clusters, since base default is still v2.3.0. Confirm multi-arch needs for Robbinsdale/St. Petersburg (Ottawa patch was amd64-only).
3. **Do not** invent a new upstream PR for these two panics; they are fixed. Any residual empty-block *data* cases should now error/empty-body instead of killing the process — investigate object state separately if writes still fail, without deleting bucket contents.
4. Track **referrers/`validate` wedge** under its own issue/workstream; do not close #527 by “fixing” that.
5. Closing #527 is reasonable once Raj accepts: Ottawa no longer panics, upstream+v2.4.0 contain the fix, and remaining delivery failures are attributed elsewhere. This agent does **not** close it unilaterally.

## What I refuted

- **“Still need an upstream patch from us for multipart/`get.rs`”** — refuted; #1522 merged; v2.4.0 has both guards.
- **“get.rs:703 is still unpatched upstream”** — refuted on `main-v2` / v2.4.0 (uses `.first().map_or`). It *was* a second panic historically; Ottawa’s `#2687` image already carried the guard before/around upstream merge.
- **“Garage panic is still the active promote blocker today”** — not supported by current Ottawa restarts/logs; do not treat #527 as the sole current delivery story.
- **“Zot config can avoid multipart and thus avoid the bug”** — previously refuted (distribution S3 Writer always CreateMultipartUpload); unchanged.
- **Conflating referrers wedge with Garage panic** — refused.

## Limits honored

- No bucket deletes, no Garage repair/restart, no promote-budget bump, no image bump applied in this turn.
- Read-only `kc.sh ot` inspection only.
- Nothing merged.
