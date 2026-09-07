# Garage `consistent` vs `degraded` — risk answer for km#2746

Date: 2026-09-07 UTC  
Question: Raj’s objection to merging fleet-wide `consistencyMode: consistent` for Kopia prune (#575 / PR purporting to fix clock-skew refusals).

**Outcome: do not merge #2746 as-is.** Raj’s site-flap concern matches our own history and Garage’s quorum table. A “fix Kopia by flipping the fleet to consistent” change re-opens the exact failure mode we deliberately left in 2026-07.

## Decisive question

**Does `consistent` turn a one-site outage (or a flapping WAN to one site) into a Garage outage?**

**Partially yes for reads; writes already need two zones.**

At **replication factor 3** (Garage upstream docs):

| Mode | Write quorum | Read quorum | Read-after-write |
| --- | ---: | ---: | --- |
| `consistent` | **2** | **2** | yes |
| `degraded` | **2** | **1** | **no** |
| `dangerous` | 1 | 1 | no |

With our three-zone layout (Ottawa / Robbinsdale / St. Petersburg):

- **One zone fully down, other two healthy**
  - **Writes:** still OK in both modes (need 2 of 3 zones).
  - **Reads under `consistent`:** need **2** replicas → both remaining zones must answer. Survives a clean one-site outage **if** the other two stay reachable and timely.
  - **Reads under `degraded`:** need **1** → local (or any single) replica is enough; this is what we use when the WAN is slow, not only when a site is hard-down.
- **One zone flapping / high latency (the homelab case)**  
  Under `consistent`, any read that cannot gather **two** timely replicas returns **503/504**. That is exactly how Zot boot and CI blob HEADs died before. Under `degraded`, those reads fall back to one replica instead of failing the request.
- **Two zones down:** below write quorum either way → object-store outage.

So: **`consistent` does not invent write fragility** (writes already require 2). It **does** remove the read soft-landing that made one flaky site survivable for Zot/CI/gateway traffic. Calling that “breaking Garage until recovered” is slightly strong for a clean one-site loss with two good sites, and **accurate for our actual failure mode: flapping/slow WAN**, which is what Raj named.

## (1) Performance / why `degraded` exists here

This was **not** an unexamined default. It is a deliberate mitigation of a real multi-site incident.

| Evidence | What it says |
| --- | --- |
| `89342b046` (2026-07-04) `garage: switch consistencyMode to degraded to fix cross-WAN read 503s` | **Author: Raj.** Federated RF=3 with consistent reads required quorum spanning zones over Tailscale. Slow/flapping links → read **503/504** → **Zot crashed on boot** (`getAllRepos`) and **CI image pushes broke** (blob HEAD). Degraded: read quorum 1; writes still quorum. Explicitly justified after restic/volsync decommission (only strict RAW consumer then). |
| Manifest comment still on `garagecluster.yaml` | Same story: degraded for cross-WAN read 503s; RAW-sensitive restic gone; OCI/Kopia/Barman framed as tolerating eventual reads. |
| `docs/reference/architecture.md` (pre-#2746) | “One zone down: reads and writes continue… Two zones down: below write quorum.” Ties survivability to **`degraded` + read quorum 1**, and warns the *reasoning* (consumer set), not RF, makes degraded safe. |
| `9102ef020` / `45341b996` (2026-05) | St. Petersburg down: drop to degraded / RF=2 so admin/S3 ops stop 503ing against missing-zone quorum. Historical proof that **consistent + missing/flaky site = operational breakage**. |
| `188e65835`…`0211e8d7f` then `f97103df8` (2026-08) | Temporary fleet `consistent` + `AssumeConsistent` for node-local drain migration, then **`fix(garage): restore degraded read quorum`** — consistent was a **bounded maintenance window**, not the steady state. |
| Upstream Garage docs | Default is `consistent`. `degraded` exists specifically to keep **reads** available when several nodes/zones are unavailable, at the cost of RAW. |

**Performance framing:** the historical pain we recorded is **availability under latency** (503/timeouts), not “CPU is higher in consistent.” For us that *is* the performance/reliability problem: reads that must wait on a flapping site become user-visible outages (registry, CI). I did not find a separate “consistent is slower on a healthy LAN” measurement in our notes; the documented motive is **cross-WAN quorum failure**.

## (2) Site flap — precise arithmetic

Assume RF=3, one replica set per zone (our federated design).

- Write quorum **2** in both `consistent` and `degraded`.
- Read quorum **2** vs **1**.

| Scenario | `degraded` | `consistent` |
| --- | --- | --- |
| 1 zone hard-down, 2 healthy | R+W OK (R=1, W=2) | R+W OK if both survivors answer (R=2, W=2) |
| 1 zone flapping / high RTT | R usually OK from local replica; W needs 2 healthy | **R fails** when second replica is the flapping zone or times out; W fails if only one solid zone answers |
| 2 zones down | W dead | W dead |

Raj’s worry maps to the **middle row**, which is our documented production pathology (`89342b046`), not a theoretical edge case.

## Does #2746 fix Kopia the right way?

#2746’s diagnosis for #575 is plausible: Kopia PUT `_maintenance` then HEAD; under degraded, HEAD can see a ~1h-stale replica → “clock skew” prune refusal despite NTP.

That does **not** imply the right fix is permanent fleet `consistent`:

1. It **reverts** the explicit post-restic mitigation that restored registry/CI under flap.
2. Architecture text already said: check before adding a RAW consumer — Kopia maintenance *is* that consumer; the answer can be “isolate RAW,” not “make the whole estate RAW.”

### Alternatives that fix prune without fleet RAW

| Approach | Idea | Why better for flap |
| --- | --- | --- |
| A. **Scoped / temporary consistent** | Flip `GARAGE_CONSISTENCY_MODE=consistent` only for a maintenance window / drain (pattern already used Aug 2026), run Kopia maintenance, restore `degraded` | Keeps steady-state flap tolerance |
| B. **Kopia-side clock** | Stop trusting Garage `Last-Modified` as the repo clock if Kopia can use server-side/local monotonic time or soften skew checks for `_maintenance` | No Garage availability tradeoff (needs Kopia/Velero feasibility) |
| C. **Dedicated RAW bucket/path on a single-site or stronger quorum store** | Put only the maintenance/control objects where RAW is cheap; leave blob estate degraded | Matches ADR direction of not overloading one Garage failure domain |
| D. **Independent backup store (ADR 0007)** | Long-term: Velero/Kopia off shared Garage | Removes coupling; doesn’t unblock prune tomorrow |

I am **not** endorsing merge of permanent consistent. Prefer **A** (operational) or **B/C** (product) after a short design pass; close or rewrite #2746 accordingly.

## Recommendation

1. **Do not merge #2746 as written** (fleet default → consistent + docs that weaken one-site survivability).
2. Tell Raj: **his flap concern is evidenced by our own July 2026 incident and Garage’s RF=3 quorum table**; degraded was chosen on purpose after restic left.
3. Treat #575 as “Kopia needs RAW for `_maintenance`,” not “Garage must run consistent always.”
4. Next step: pick A/B/C; if A, automate a documented maintenance window rather than a silent GitOps permanent flip.

## What I refuted

- **“degraded was just an unreviewed default”** — refuted; deliberate commit + long comment + architecture section + later restore-after-migration.
- **“consistent only affects writes”** — refuted; write quorum unchanged (2); **reads** are what degrade→1 vs consistent→2.
- **“one site down always bricks consistent Garage”** — slightly overstated for a clean two-survivor case; **accurate for flap/latency**, which is our real world.
- **“Must merge consistent to fix Kopia”** — false dichotomy; scoped consistent or non-Garage clock are alternatives.

## Limits

Read-only git/docs/upstream; no cluster apply; no advocacy for #2746 merge.
