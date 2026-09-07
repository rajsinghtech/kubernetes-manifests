# Control-plane static-pod memory request survey (#700 follow-on)

**Read-only.** No Talos apply. No machine-config edits for Ottawa/Robbinsdale in this change set — proposals only.

Companion to StP procedure in `700-apiserver-memory-request.md` / #700.

## Judgment

| Cluster | Urgency | Why |
|---------|---------|-----|
| **St. Petersburg (orin-0)** | **Urgent** (already filed #700) | ~5.4 Gi allocatable; apiserver ~4.3 Gi RSS vs 512 Mi request; node WorkingSet **>100%** of allocatable; sole CP |
| **Ottawa** | **Tidy-up, not urgent** | ~89 Gi allocatable CP nodes; apiserver ~4.4–4.6 Gi vs 512 Mi; **~49–66 Gi free by usage**; request pressure only ~40–44% |
| **Robbinsdale** | **Tidy-up, not urgent** | ~28–60 Gi allocatable; apiserver ~2.7–3.4 Gi vs 512 Mi; **~15–40 Gi free by usage**; no MemoryPressure |

The same **class of lie** exists everywhere (512 Mi request, multi-Gi RSS, no limit). It is only **dangerous** where headroom is small and there is no CP HA — that is StP. Ottawa/RB will not “become orin-0” without a much larger packing mistake; raising requests there is honesty/hygiene and a rolling brief API blip on each CP node, not an eviction firefight.

## Numbers (2026-09-07, read-only)

Memory from `kubectl top` (WorkingSet-ish) and `describe node` Allocated requests.

### kube-apiserver

| Node | Allocatable | Node mem used (top) | Requests allocated | Scheduler “free” (100−req%) | Free by usage | API req | API RSS | Gap |
|------|-------------|---------------------|--------------------|-----------------------------|---------------|---------|---------|-----|
| ot/asuka | 89.3 Gi | 45% / 41 Gi | 44% | ~50 Gi | ~49 Gi | 512 Mi | 4505 Mi | **~4.0 Gi** |
| ot/kaji | 89.3 Gi | 26% / 24 Gi | 40% | ~54 Gi | ~66 Gi | 512 Mi | 4633 Mi | **~4.1 Gi** |
| ot/rei | 89.3 Gi | 37% / 33 Gi | 42% | ~52 Gi | ~57 Gi | 512 Mi | 4491 Mi | **~4.0 Gi** |
| rb/stone | 60.0 Gi | 54% / 33 Gi | 38% | ~37 Gi | ~28 Gi | 512 Mi | 3362 Mi | **~2.8 Gi** |
| rb/tank | 59.3 Gi | 32% / 19 Gi | 26% | ~44 Gi | ~40 Gi | 512 Mi | 3084 Mi | **~2.6 Gi** |
| rb/titan | 28.5 Gi | 47% / 14 Gi | 42% | ~17 Gi | ~15 Gi | 512 Mi | 2745 Mi | **~2.2 Gi** |
| sp/orin-0 | **5.4 Gi** | **112% / 6.2 Gi** | **65%** | **~1.9 Gi** | **negative** | 512 Mi | 4291 Mi | **~3.8 Gi** |

All apiservers: **no memory limit**.

### Other static control-plane pods (fleet pattern?)

| Component | Default request | Observed RSS range | Under-request? |
|-----------|-----------------|--------------------|----------------|
| kube-apiserver | 512 Mi | **2.7–4.6 Gi** | **Yes — systemic (~5–9×)** |
| kube-controller-manager | 256 Mi | 28–449 Mi | **No** (at most ~1.8× on one Ottawa node; others under request) |
| kube-scheduler | 64 Mi | 59–101 Mi | **Mild / no** (~1–1.6×) |
| etcd | n/a as Pod | **Not present as a kube-system Pod** on ot/rb/sp | Talos runs etcd as a **host service**; it does not participate in Pod request accounting |

**Fleet answer:** the pathological pattern is **kube-apiserver-specific**, not “all static pods request 512 Mi and use 4 Gi.” Controller-manager and scheduler are roughly honest. Etcd is outside the Pod request model entirely on Talos.

## Proposed fix for Ottawa / Robbinsdale (not applied)

Same shape as StP #700: Talos `cluster.apiServer.resources.requests` only; **no limit**.

Suggested values (hygiene, not emergency):

| Cluster | Suggested request | Notes |
|---------|-------------------|--------|
| Ottawa | **4000Mi** | RSS ~4.4–4.6 Gi; 4 Gi still leaves tens of GiB free on 89 Gi nodes |
| Robbinsdale | **3000Mi** | RSS ~2.7–3.4 Gi; titan is the smallest CP (~28 Gi) — 3 Gi is honest without crowding |

Example patch body (per cluster `patches/controller/apiserver-resources.yaml`):

```yaml
# PROPOSAL ONLY — wire into controlPlane.patches after approval; apply via talosctl.
cluster:
  apiServer:
    resources:
      requests:
        cpu: 200m
        memory: 4000Mi   # Ottawa; use 3000Mi on Robbinsdale
```

Apply implications (multi-CP):

- Rolling `talosctl apply-config --mode=no-reboot` **one node at a time**.
- Each apply **restarts that node’s apiserver static pod** → brief loss of one API endpoint; etcd quorum / other apiservers keep the cluster available if done serially and health is checked between nodes.
- Much safer than StP’s sole-CP blip, but still schedule a maintenance window.

Do **not** treat Ottawa/RB as the same urgency as orin-0: scheduler free memory is still measured in tens of GiB.

## What to do when

1. **Now:** StP #700 (3500 Mi on orin-0) — already documented.
2. **Later tidy-up:** Ottawa 4000 Mi, Robbinsdale 3000 Mi, serial apply.
3. **Optional follow-up:** investigate *why* apiserver RSS is 3–4 Gi (watch cache / LIST load); raising requests does not explain growth.
4. **Skip:** raising controller-manager / scheduler requests fleet-wide — data does not justify it.

## Method notes

- `kubectl top` used for RSS; node `Allocated resources` for scheduler-visible requests.
- Ottawa CP role column empty in one listing but apiserver pods pin asuka/kaji/rei — treated as CP.
- etcd absence as Pod confirmed via kube-system inventory on all three clusters.
