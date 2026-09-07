# #677 decision memo — option 2 vs option 3

Architecture decision only. **Do not apply.**  
Option 1 (UniFi live-flow affinity) is already off the menu: multipath membership
is visible; mid-flow re-hash is not (`docs/incidents/677-unifi-ecmp-observability.md`).

This memo answers the remaining deciding question: **what exactly breaks if the
public VIP stops preserving real client source IPs**, and what option 2 actually
buys after that.

## Short recommendation

**Prefer option 3 (`externalTrafficPolicy: Cluster`) unless Raj has an
unlisted consumer of public client IPs outside this repo/runtime.**

Reason: on the paths we ship, client source IP is **observability-only**, not
authorization. Option 2 preserves that observability but **still drops in-flight
TCP on node failure**, while giving away half of public Envoy capacity / one
failure domain. Option 3 removes the Local+ECMP wrong-node RST class without
collapsing HA, at the cost of SNAT-masked IPs in Envoy/SSH edge telemetry.

If the requirement is “never lose `65.35.213.179` in logs,” choose option 2
knowingly — not because auth depends on it.

---

## What uses client source IP today?

### Authorization — **not IP**

| Control | Mechanism | IP load-bearing? |
|---------|-----------|------------------|
| Workspace `SecurityPolicy` (82 total; 53 with `authorization`) | `principal.headers.Remote-Email` allow-lists | **No** — 53/53 email; **0** IP/`sourceAddresses` |
| `bhaiya-tinyauth` on public CDN HTTPRoute | tinyauth extAuth → injects `Remote-Email`; bhaiya authZ on users table | **No** |
| `CiliumNetworkPolicy/bhaiya-ssh-ingress` | Ingress **from Envoy proxy pods** by label on `:2223` | **No** — never matches public client CIDRs |
| `CiliumNetworkPolicy/bhaiya-ingress` | From Envoy / ssh-edge / mcp / Prometheus by label | **No** |

Live sample workspace policy shape: `defaultAction: Deny` + Allow rules on
`Remote-Email` values only.

**Conclusion:** flipping to Cluster does **not** silently open or close
workspace access. Auth stays email / SSH key based.

### SSH edge — logs identity, not IP

`bhaiya-ssh` session start/end structured logs (live, last hours) carry
`session_id`, `workspace_slug`, `key_fingerprint`, byte counts, termination
fields. **No `client_ip` / `remote_addr` field appears in those events.**

SSH authn is key fingerprint → workspace binding (`BHAIYA_SSH_AUTH_*`), not
peer IP. CNP already assumes the only L4 clients of the ssh-edge are Envoy
pods.

Under Cluster, the TCP peer seen by Envoy (and thus any future `RemoteAddr`
plumbing) becomes a **node IP** after SNAT. Today that peer is the real client
only because Local preserves it. Losing it degrades **forensic correlation**
(“which residential IP?”), not session authz.

### Envoy / HTTP observability — **yes, IP appears; not enforced**

- Public `EnvoyProxy` forgejo-ssh access logs include
  `downstream_remote_address` (today = real client).
- `ClientTrafficPolicy/wildcard-lan` sets `clientIPDetection.xForwardedFor.numTrustedHops: 1`
  for Gateways `public` + `private`. That feeds **HTTP** client-IP detection /
  logging. No `SecurityPolicy` rate-limit or IP allow-list consumes it.
- Repo-wide: **no** `sourceAddresses` / `ipBlock` / `RemoteIP` fields on any
  SecurityPolicy; no public-gateway IP rate-limit objects found.

Under Cluster without Proxy Protocol: HTTP app views of “client IP” via XFF
trusted-hop logic become **node addresses** unless something else restores the
outer client (there is no Proxy Protocol config on this EnvoyProxy today).

### What Cluster would break / degrade

| Surface | Effect of Cluster | Severity |
|---------|-------------------|----------|
| Workspace / bhaiya HTTP authZ | Unchanged (Remote-Email) | None |
| SSH key → workspace authZ | Unchanged | None |
| CNP ssh-edge | Unchanged (Envoy→edge) | None |
| Envoy `downstream_remote_address` on `:22` / `:443` | Shows node IP, not `65.35.213.179` | Observability |
| HTTP clientIPDetection / XFF | Likely node IP | Observability |
| Incident correlation (#661 style) | Harder to join laptop IP ↔ Envoy row without another signal | Observability |
| Abuse IP bans / geo (if anyone does them out-of-band) | Would need another handle | **Unknown outside repo** — call out |

**Not found:** IP allow-lists, IP rate limits, or IP-keyed alerts on this path.

---

## Option 2 — single advertising node (priced)

### What it fixes

Steady-state UniFi ECMP across two Local-only backends. With one BGP next hop
for `10.169.10.15/32`, mid-flow hash flips between rei and kaji stop by
construction.

### What it does **not** fix

**Node / pod failure still drops established TCP.** There is no socket state
sync between Envoy replicas. Failover = new SYN on the surviving path; old
five-tuples die. Option 2 is **not** “HA without drops”; it is “no dual-next-hop
rehash in the healthy steady state.”

### Capacity / failure-domain cost

Current public Envoy:

- `replicas: 2`
- `topologySpreadConstraints … whenUnsatisfiable: DoNotSchedule` on hostname
- Live pods: one on **rei**, one on **kaji**
- With Local, each node’s Cilium frontend points only at the local pod
- UniFi RIB: VIP has **exactly those two** next hops in use

Practical implementations of “single advertiser”:

| Implementation | Steady-state capacity | Failure domain | Notes |
|----------------|----------------------|----------------|-------|
| `replicas: 1` | **½** of today | One node + one pod | Simplest GitOps; loses spread |
| Pin Deployment to one node (affinity) with `replicas: 2` | Still one node’s NIC/CPU for external | One node; second pod unused or Pending | Wasteful / fights DoNotSchedule |
| Keep 2 nodes but advertise VIP from one via BGP surgery | External capacity still one backend under Local | Complex; easy to get wrong | Not recommended |

Under Local, **external** useful capacity ≈ number of advertising nodes with a
ready local Envoy. Single advertiser ⇒ **one Envoy receives all public VIP
traffic**; the other replica does not take external connections.

Private VIP `10.169.10.14` is the same dual-path shape today; this memo’s
change surface for #677 is the **public** VIP / `envoyproxy-public` unless Raj
widens scope.

### Residual risk

- Healthy dual-path rehash: fixed  
- Advertising node down / Envoy crash: sessions drop (same as today on that
  failure, but **no second next hop** to absorb new connections until reschedule)
- Does not require UniFi hash visibility  

---

## Option 3 — `externalTrafficPolicy: Cluster` (priced)

Draft (still unapplied): set on `envoyproxy-public` `envoyService`:

```yaml
externalTrafficPolicy: Cluster
```

### What it fixes

Wrong-node packets can be forwarded to the Envoy that owns the socket’s
backend path instead of meeting a Local-only frontend with no tuple → local
RST. This is the mechanism class implicated by dual-node capture + CT + public
vs Tailscale A/B (Tailscale VIP is not this ECMP pair).

### What it costs

- Real client source IP lost at Envoy/backend (SNAT at receiving node)
- Observability / forensics degradation above
- Extra hop + node conntrack for cross-node forward (usually fine at this scale)
- **Does not prove** every #661 drop was ECMP; it removes one our-side mechanism.
  Validate with dual-node capture + sshrepro public A/B after change.

### What it preserves

- Two Envoy replicas, two nodes, topology spread  
- Public VIP capacity and node failure domain for **new** connections  
- All Remote-Email / SSH-key authorization  

Acceptance checks if chosen (from earlier analysis, still valid):

1. Service shows `externalTrafficPolicy: Cluster`
2. Cilium external frontend on each node lists **both** Envoy backends
3. Dual-node capture: no Local wrong-node RST pattern for live tuples
4. Explicit OK that logs may show node IPs
5. Watch high-volume SSH; do not declare #661 fixed unless drops stop

---

## Side-by-side

| | Option 2 single advertiser | Option 3 Cluster |
|--|----------------------------|------------------|
| Removes Local+ECMP rehash RST class | Yes (no second NH) | Yes (forward path exists) |
| Preserves real client IP | **Yes** | **No** |
| AuthZ impact | None found | None found |
| Public Envoy HA / capacity | **Cuts external to one node** | Keeps two nodes |
| Node failure in-flight sockets | Still drop | Still drop |
| GitOps complexity | Affinity/replica change; fight spread | One field on EnvoyProxy |
| Needs UniFi observability | No | No |
| Proves #661 root cause | No | No |

---

## Decision ask for Raj

Pick one:

1. **Ship option 3** — accept observability-only IP loss; keep HA; measure drops.  
2. **Ship option 2** — keep real client IPs; accept single-node external capacity
   and that failover still drops sockets.  
3. **Defer** — live with #683 reconnect mitigation + Tailscale path for critical
   work until willing to spend HA or IP fidelity.

If you know of an out-of-repo consumer (ISP tickets, Fail2ban, geo ACL, etc.)
that keys on public VIP client IPs, say so before option 3 — that is the only
authZ/abuse class this memo could not see from GitOps + live policies.
