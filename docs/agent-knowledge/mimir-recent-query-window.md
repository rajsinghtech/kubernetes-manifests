# #674 Mimir recent query window — risk and cheapest correct fix

Worktree: `/workspace/worktrees/km/mimirwindow`  
Branch: `work/mimirwindow`  
Remote confirmed: `https://github.com/keiretsu-labs/kubernetes-manifests.git`  
Base: `origin/main` @ `393883e9b`  
Date: 2026-09-06 UTC

## Confirmed live state (Ottawa, read-only)

| Fact | Evidence |
| --- | --- |
| One ingester | `sts/mimir-ingester` replicas **1**, pod `mimir-ingester-0` 1/1 |
| RF = 1 | Live `mimir-config`: `ingester.ring.replication_factor: 1`, CLI `--ingester.ring.replication-factor=1` |
| `query_store_after` not set | Querier config only has `max_concurrent: 8` → **default 12h** applies |
| Related defaults also unset | No `ignore_blocks_within` / `query_ingesters_within` overrides → defaults **10h** / **13h** |
| PVC migration landed | Bound `storage-mimir-ingester-0` 20Gi `ceph-block-replicated`; emptyDir replaced via post-renderer |
| `flush_blocks_on_shutdown: true` | Present in live config (helps **future** shutdowns; could not protect the introducing rollout) |
| Ingester age | Started **2026-09-06T14:54:50Z** (~9h before this probe) |
| Ingester cost today | **~4.0–4.1 GiB RSS**, ~135–140m CPU; requests only `100m` / `512Mi` |

## Diagnosis verification (falsifiable prediction held)

Issue #674 predicted the ~11h empty window was mostly **unreadable**, not deleted, and that the leading edge would recede as `now - 12h` advances.

Probe of `count(up)` for tenant `talos-ottawa` at ~23:59Z:

| Wall time (UTC) | Offset | Result |
| --- | ---: | --- |
| 15:59 → 14:59 | 8–9h | readable (256/252) |
| 14:29 → 12:29 | ~9.5–11.5h | **EMPTY** |
| 11:59 and older | ≥12h | readable (252) |

So the empty band has already shrunk to roughly **~12:30–14:50Z** (~2–3h), matching the “never-shipped tail around migration” estimate. Data older than the store cutoff is back. **Diagnosis confirmed.**

`cortex_ingester_shipper_uploads_total` is **12** on the new ingester — shipping is alive again.

## What is actually at risk

**Not at risk (mostly):** long-term blocks in Garage/object storage. Compactor/store-gateway already served pre-migration hours once they aged past `query_store_after`.

**At risk on every single-ingester loss/restart/OOM/eviction/node move:**

1. **Queryable recent window ≈ last 12h** (ingester-only by default).
2. **Permanent loss ≈ unshipped head** at death (minutes to a few hours depending on ship cadence / whether flush-on-shutdown runs under the *new* config).
3. **All dashboards and Mimir-ruler alerts that need that recent window**, including the backup/delivery alerts that depend on fresh samples — exactly when you are debugging the outage that killed the ingester.

The RBD PVC removes “node-local emptyDir death ⇒ total WAL loss on that node,” but **does not** remove the queryability SPOF while `query_store_after=12h` and `replicas=1`.

## Detection already present

`feat(monitoring): alert on Mimir recent query window (#2725)` added:

- recording rule `mimir_query_canary`
- alert `MimirRecentQueryWindowUnavailable` (6h absent vs 13h present, `for: 10m`, critical)

Wired into `kustomization.yaml` + all three loader tenants. Live `mimir_query_canary` returns **1** now; the alert is **not** firing because the 6h offset is currently readable (expected after the gap receded past 6h).

**Limit (already documented in the rule):** it shares the Mimir ruler/query path, so it is not an independent external probe of the gateway. It *does* catch the specific “recent window gone, older store still fine” failure mode #674 cares about.

## Options ranked by blast radius / cost

### A. Do nothing beyond the alert (status quo + detection)

- **Pros:** already merged; no capacity burn.
- **Cons:** next ingester replacement still blinds ~12h of queries; alert pages you into a known bad window rather than preventing it.

### B. Lower `querier.query_store_after` (and align companions) — cheapest *mitigation*

Example shape (illustrative, not applied):

```yaml
querier:
  query_store_after: 4h          # or 6h
  query_ingesters_within: 5h     # must stay > query_store_after
blocks_storage:
  bucket_store:
    ignore_blocks_within: 3h     # must stay < query_store_after
```

- **Pros:** no extra ingester RAM/CPU/PVC; shrinks the blind window after blocks exist in the store; config-only.
- **Cons:** does **not** eliminate RF=1 SPOF for the remaining window; store-gateway/Garage get more recent-range read load; must keep the three knobs ordered or queries go weird; the canary alert’s 6h offset must be updated if the window drops ≤6h.
- **Fit:** good partial fix if Raj wants less pain **without** paying for another ingester.

### C. Second (or third) ingester + RF≥2 — real availability fix

- **Pros:** recent window survives losing one ingester; matches how Mimir is meant to run for HA.
- **Cons / numbers Raj must accept:**
  - Current ingester RSS **≈4.1 GiB** with a **512Mi** request (already badly under-requested). A second replica is roughly **another ~4 GiB RAM** plus another **20Gi** replicated RBD PVC, plus RF/ring/topology decisions (`zoneAwareReplication` is currently **false**).
  - RF=2 with 2 replicas is still awkward (no true majority); RF=3 wants 3 ingesters and usually zone-awareness — **~12 GiB RAM** class cost before headroom.
  - StatefulSet + separately managed PVC pattern (`storage-mimir-ingester-0` only) must be extended carefully; chart `persistentVolume.enabled` is intentionally off because of immutable PVC template constraints.
- **Fit:** correct HA answer; **capacity / topology decision from Raj**, not something to sneak in.

### D. “Both” (B then C)

Shrink the blind window now; schedule HA ingesters when RAM/PVC budget is approved.

## Sequencing defect (still real, separate from RF)

`flush_blocks_on_shutdown: true` cannot protect the rollout that **introduces** it when volume+config move together — terminating pod still runs old config. Future migrations of this shape need **config-first, volume-second** rollouts. Documented in #674; still worth an ADR/runbook note, not an emergency config change tonight.

## Recommendation

1. **Treat #2725’s alert as the detection half — already done.** Do not pretend “nothing alerts.”
2. **Do not change replication factor or ingester count in this change** without an explicit capacity decision. Numbers: **~4.1 GiB RSS per ingester today**, requests lying at 512Mi, **20Gi** PVC each, RF/zone topology currently single-replica / non-zone-aware.
3. **Cheapest correct *mitigation* if Raj wants a config-only improvement:** lower and explicitly set the query/store freshness triad (`query_store_after`, `ignore_blocks_within`, `query_ingesters_within`) and retune the canary offsets in the same commit. That reduces, not removes, the SPOF window.
4. **Correct availability fix:** ≥2 (preferably 3) ingesters with matching RF and honest memory requests — **needs Raj’s capacity call.**

## What I refuted

- **“Data for the whole 11h was deleted”** — refuted by the receding gap and readable pre-cutoff samples.
- **“PVC fixed the recent-window problem”** — refuted; PVC helps durability of *this* ingester’s disk, not querier freshness policy.
- **“Nothing alerts on this”** — partially refuted: `#2725` already added `MimirRecentQueryWindowUnavailable`. Gap: it is not an external blackbox, and it will not fire once the hole is older than the 6h probe offset.
- **“Just bump RF in Git and move on”** — refused without capacity numbers; live RSS makes that a real spend.

## Limits honored

- Read-only cluster inspection via `tools/kc.sh ot` (`get`/`top`/`describe`/`exec` config read only; no apply/patch).
- No merge. No RF/replica change applied.
