# #700 — raise StP kube-apiserver memory request (procedure)

**Status: NOT APPLIED.** Reviewable Git patch + operator apply steps only.

## Where the setting lives

| Layer | In git? | Path |
|-------|---------|------|
| Desired machine config | **Yes** | `clusters/talos-stpetersburg/bootstrap/talos/` (`talconfig.yaml` + `patches/`) |
| Rendered node configs | **No** (gitignored) | `…/clusterconfig/` via `mise run genconfig` / talhelper |
| Live node | Out-of-band apply | `talosctl` / `mise run apply` against orin-0 |

This is **not** a Flux/Kubernetes manifest. Changing YAML in `kubernetes/apps/` cannot fix it. The durable source of truth **is** in this repo’s Talos patches; what is *not* GitOps’d is the **apply** step to the machine.

Stale note: `bootstrap/talos/README.md` still says all three nodes are control plane / share VIP. `talconfig.yaml` is authoritative: **orin-0 is the sole `controlPlane: true` node** (`allowSchedulingOnControlPlanes: false`). Spark nodes are workers. Blast radius is therefore **the only API server**.

Live (2026-09-07, read-only): request still `512Mi`, usage ~`4157Mi`, restarts `0`, `MemoryPressure=False` at check time (was True during HA eviction window). Ottawa/Robbinsdale also request `512Mi` while using ~2.7–4.6Gi — same class of lie, multi-CP so less acute.

## Patch shape (Talos `v1alpha1`)

Talos field: `cluster.apiServer.resources.requests` (`ResourcesConfig` in siderolabs machinery).

Proposed file (committed as draft in this branch):

`clusters/talos-stpetersburg/bootstrap/talos/patches/controller/apiserver-resources.yaml`

```yaml
cluster:
  apiServer:
    resources:
      requests:
        cpu: 200m
        memory: 3500Mi
```

Wire it from `talconfig.yaml` under `controlPlane.patches` (orin-0 is the only CP, so controller patches apply only there):

```yaml
controlPlane:
  patches:
    - "@./patches/controller/api-access.yaml"
    - "@./patches/controller/disable-proxy.yaml"
    - "@./patches/controller/kubelet-certs.yaml"
    - "@./patches/controller/etcd-metrics-patch.yaml"
    - "@./patches/controller/apiserver-resources.yaml"  # NEW
```

### Exact value choice

| Value | Rationale |
|-------|-----------|
| **3500Mi request (recommended)** | Below current ~4.1Gi RSS so we don’t claim more than allocatable allows after other system pods; still closes most of the scheduler lie (512→3500). Leaves ~2Gi allocatable for Guaranteed HA + CNI on a 5665464Ki (~5.4Gi) allocatable node. |
| 4000Mi request | Matches RCA upper band; tighter vs other orin-0 system requests (~1.1Gi+ already). Prefer only if top stays ≥4Gi after a quiet period. |
| Limit unset | **Do not set a memory limit** in this change. OOMKill of kube-apiserver on a **single** control-plane node is a hard API outage. Bounding growth is a separate decision with explicit downtime acceptance. |

CPU request left at Talos default `200m` (unchanged).

## Apply procedure (after merge of the patch into `main`, or from this branch with approval)

Do this from a machine with StP Talos credentials (`TALOSCONFIG` / mise env under `clusters/talos-stpetersburg`).

1. **Freeze scheduling risk:** confirm HA is Guaranteed and MemoryPressure state; optionally cordon is N/A for static pods.
2. **Generate configs**
   ```bash
   cd clusters/talos-stpetersburg
   mise run genconfig
   ```
   Diff the rendered orin-0 machine config for `cluster.apiServer.resources`.
3. **Apply to orin-0 only** (default `talhelper gencommand apply` may target all nodes — restrict to the CP):
   ```bash
   # Preferred: node-scoped apply after genconfig
   talosctl --nodes orin-0 --endpoints orin-0.stpetersburg.internal \
     apply-config --file bootstrap/talos/clusterconfig/<generated-orin-0.yaml> \
     --mode=no-reboot
   ```
   If using mise wrappers, verify the generated command’s node list **before** piping to bash (`talhelper gencommand apply` then edit/filter). Do **not** use `apply-insecure` (maintenance) or `reset`.
4. **Expect an apiserver container restart** when static-pod resources change under `--mode=no-reboot`: kubelet reconciles `/etc/kubernetes/manifests` and recreates `kube-apiserver-orin-0`. That is a **brief control-plane outage** on StP (sole CP): API calls fail until the new apiserver passes ready. Etcd on the same node typically stays up; controllers may transiently error. Plan a quiet window; warn anyone using StP kubectl/Flux.
5. **Watch**
   ```bash
   kubectl --context <stpetersburg> get --raw='/readyz?verbose'
   kubectl -n kube-system get pod kube-apiserver-orin-0 -w
   kubectl -n kube-system get pod kube-apiserver-orin-0 \
     -o jsonpath='{.spec.containers[0].resources}{"\n"}'
   kubectl top pod -n kube-system kube-apiserver-orin-0
   kubectl describe node orin-0 | rg -A20 'Allocated resources'
   ```
   Success: request shows `3500Mi`; Allocated requests jump; no sustained MemoryPressure; HA remains Running.
6. **Rollback:** revert the patch commit, `genconfig`, `apply-config --mode=no-reboot` again (another brief apiserver restart).

### Blast radius summary

| Item | Effect |
|------|--------|
| Nodes touched | **orin-0 only** (sole CP) |
| Spark workers | Untouched if apply is node-scoped |
| Apiserver restart | **Yes** (static pod recreate) — short API downtime |
| Etcd data | Not wiped by this apply |
| HA / local-path pods | Survive if memory headroom OK; at risk only if node OOMs during restart churn |
| Flux | May show reconcile errors during API blip |

## What this does / does not fix

- **Does:** Make the scheduler reserve ~3.5Gi for apiserver so orin-0 no longer looks “empty” while RSS is ~4Gi.
- **Does not:** Cap further growth (no limit); explain *why* usage is ~4Gi; fix Ottawa/Robbinsdale’s same 512Mi lie; remove HA’s local-path pin.

## Finding: apply is the gap, not “config missing from git”

Machine config **is** reviewable in git. Generated `clusterconfig/` is intentionally untracked. There is **no Flux path** to push Talos machine config — every CP resource change requires a human `talosctl apply`. That is worth treating as an operational gap (checklist / runbook ownership), not as “unknown out-of-band only” configuration.
