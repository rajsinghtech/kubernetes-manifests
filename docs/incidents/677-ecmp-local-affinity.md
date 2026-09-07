# #677 — externalTrafficPolicy Local + ECMP needs live-flow affinity

Status: analysis only. **No production change applied.**

## Port-reuse check (done first)

Queried Envoy `forgejo-ssh` / `:10022` access logs on both public pods
(`rei` + `kaji`), current (~3h) and previous container logs.

| Check | Result |
|-------|--------|
| Unique `:10022` records | 162 |
| Source tuples on **both** nodes | **0** |
| Same-node source-port reuse (multiple records) | **0** |
| Historical dual-capture ports `:51061`, `:51187` | exactly **one** Envoy record each, on **kaji**; none on rei |
| Raj `65.35.213.179` RemoteResets in retention | all on **kaji** |

**Conclusion: source-port reuse is not supported** as the explanation for the
dual-node packet observations in #661.

Important nuance: under `externalTrafficPolicy: Local`, a mid-stream segment
that lands on the wrong node never becomes an Envoy connection (the node has no
established tuple / no listening socket ownership for that flow and can RST
locally). So the *absence* of a rei Envoy record for those ports is exactly what
a flow-selection split predicts; it does not revive the reuse hypothesis.
Packet evidence from the earlier dual-node capture (live ACK for a current
`kaji` sequence appearing on `rei`, followed by an immediate local
`10.3.2.229:10022` RST) remains the reason the ingress path stays open.

## Live topology still matches the failure mode

Read-only check on 2026-09-07:

- Service `envoy-home-public-ea71a69f`: `externalTrafficPolicy: Local`,
  `sessionAffinity: None`, VIP `10.169.10.15`, SSH NodePort `31015` → `10022`.
- EnvoyProxy CRD default for `externalTrafficPolicy` is **Local**; our
  `envoyproxy-public.yaml` does not override it (only sets `loadBalancerIP`).
- Cilium realized external frontends:
  - rei: `10.169.10.15:22` → **only** `10.3.2.229:10022`
  - kaji: `10.169.10.15:22` → **only** `10.3.1.231:10022`
- BGP: both peers established; both advertise `10.169.10.15/32` with distinct
  next hops `192.168.169.118` (rei) and `192.168.169.119` (kaji).

So the design property in #677 still holds: upstream ECMP across two
Local-only backends has no live-flow affinity.

## Remedy comparison (decision needed — do not apply reactively)

### 1. Upstream connection affinity / resilient ECMP (UniFi)

- Preserves client source IP and Local policy.
- Depends on UniFi/BGP hash stability across soft-resets and next-hop churn.
- **Blocked on observability we do not have**: UniFi RIB/ECMP history was not
  inspected; Cilium BGP soft resets were frequent and non-diagnostic (#661).
- Cost: router-side work + ongoing verification. No GitOps PR in this repo alone.

### 2. Single advertising node (primary/standby)

- Removes steady-state ECMP split; preserves source IP.
- Failover still cannot migrate an established TCP socket; node failure still
  drops in-flight sessions.
- Implementation options: pin Envoy public replicas to one node (defeats the
  existing topologySpread), or change Cilium BGP advertisement so only one
  next hop carries `10.169.10.15/32`.
- Cost: capacity/failure-domain trade-off; needs an explicit acceptance that
  one node owns public TCP.

### 3. `externalTrafficPolicy: Cluster`

- Wrong-node packets can forward to the owning Envoy endpoint → eliminates the
  Local-only tuple mismatch class.
- **Trade-off: backends lose the original client source IP** (see node SNAT).
  That affects Envoy `downstream_remote_address`, SSH gateway peer telemetry,
  and any IP-based audit/rate logic on the public path.
- Implementation is a one-line EnvoyProxy change (see draft below). Reversible.
- Does **not** prove #661 is caused by ECMP; it removes one concrete our-side
  mechanism. Client-host / client-middlebox remain possible.

### Draft change (NOT applied)

In `kubernetes/apps/base/home/home/local-gateway/envoyproxy-public.yaml`:

```yaml
      envoyService:
        externalTrafficPolicy: Cluster
        loadBalancerIP: ${CLUSTER_LOAD_BALANCER_CIDR%.*.*/*}.10.15
```

Acceptance criteria if chosen:

1. Service shows `externalTrafficPolicy: Cluster`.
2. Cilium external frontend on each node lists **both** Envoy backends.
3. A dual-node capture no longer shows wrong-node local RSTs for a live
   five-tuple (or shows forwarding instead).
4. Explicit sign-off that public SSH/HTTP telemetry may see node IPs instead of
   `65.35.213.179`.
5. Long-lived high-volume SSH still watched — this change must not be described
   as fixing #661 unless drops stop.

## What this issue is / is not

- **Is:** an ingress design risk independent of the still-open client/middlebox
  candidates for #661.
- **Is not:** a proven root cause of every RemoteReset, and not a reason to
  reopen Envoy-as-closer / keepalive / Cilium CT eviction (already eliminated).

## Recommended decision framing for Raj

1. If preserving client source IP is non-negotiable → pursue (1) or (2); do not
   ship (3).
2. If eliminating the Local+ECMP RST class quickly matters more than source IP
   on the public VIP → ship (3) as a staged experiment with the acceptance
   criteria above, while #683 reconnect mitigation covers blast radius.
3. Either way, do not treat a GitOps flip as diagnosis of #661.
