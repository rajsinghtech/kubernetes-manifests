# #677 — UniFi ECMP / RIB observability (read-only)

Status: investigation complete. **No UniFi or cluster reconfiguration.**

Branch: `work/unifi-obs`. Companion to `docs/incidents/677-ecmp-local-affinity.md`.

## Bottom line

**We can see that UniFi is doing multipath ECMP for `10.169.10.15/32`. We cannot see a mid-flow re-hash, the hash algorithm, per-flow next-hop selection, or RIB change history with what we have today.**

That turns remedy option 1 ("upstream connection affinity / resilient ECMP") from vague into a concrete decision:

- **Observable now:** multipath membership (which next hops are installed / `in_use`).
- **Not observable now:** whether a live five-tuple moved between those next hops, why, or when.
- **Therefore option 1 is not operable as a measured fix** until we add one of the “what would be needed” items below (or accept operating blind and only verifying after the fact via dual-node packet captures).

## What we can see today

### 1. Checked-in UDM FRR config (static intent)

`clusters/talos-ottawa/unifi/frr.conf`:

- ASN `64515`, peers Cilium nodes `.116–.119` as group `cilium` / ASN `64514`
- `maximum-paths 4`
- `bgp graceful-restart`, soft-reconfiguration inbound
- **No** resilient-hash / consistent-hash / flow-affinity knobs in the checked-in file

This documents intent. It is not a live telemetry stream.

### 2. UniFi Network API (API key from `home/external-dns-unifi-secret`)

Gateway: `https://192.168.169.1` (UDM / UCGF `kusanagi`, Network `10.6.101`, console `5.1.31`).

| Endpoint | Result | Useful for ECMP? |
|----------|--------|------------------|
| `GET /proxy/network/v2/api/site/default/routes` | **200**, 379 routes | **Yes — live RIB snapshot** |
| `GET …/api/s/default/stat/routing` | 200 empty `[]` | No |
| `GET …/api/s/default/rest/routing` | 200 empty `[]` | No |
| `GET …/api/s/default/rest/bgp*` | 400 | No BGP neighbor API |
| `GET …/v2/api/site/default/bgp` | 404 | No |
| `GET …/stat/bgp` | 404 | No |
| Integration `v1/sites`, `v1/info` | 200 | Inventory only |
| `v2/…/traffic-flows` | 405 | Not a usable GET flow table |

**Live VIP row (observed):**

```json
{
  "destination": "10.169.10.15/32",
  "distance": 20,
  "origin": "BGP",
  "type": "unicast",
  "nexthops": [
    {"gateway": "192.168.169.118", "in_use": true, "weight": 1},
    {"gateway": "192.168.169.119", "in_use": true, "weight": 1}
  ]
}
```

So UniFi currently installs **both** rei and kaji as active equal-cost next hops for the public Envoy VIP. That confirms the ECMP topology; it does not attribute any one TCP five-tuple to a next hop.

Many other BGP `/32`s show four next hops (all Cilium nodes) with `maximum-paths 4`. The public VIP’s two-path shape matches only rei/kaji advertising that Service frontend.

### 3. unpoller (Prometheus)

Scrapes `https://192.168.169.1` as user `unpoller`. Metric surface is controller/device/client/DPI/WAN/site health.

**No** `bgp`, `route`, `rib`, `fib`, `nexthop`, or `ecmp` metric families. Cannot alert on RIB churn or multipath membership changes via unpoller alone.

### 4. SNMP

Device object from the Network API exposes **no SNMP fields**. No evidence SNMP is enabled or exporting BGP MIBs. Not pursued further (would require device changes).

## Can we detect a mid-flow re-hash?

| Method with current tooling | Verdict |
|----------------------------|---------|
| Poll `/v2/.../routes` and diff next-hop sets | Detects **membership** changes (path add/remove). **Misses** re-hash while both next hops stay `in_use=true` — the common steady state for this VIP. |
| Correlate drops with Cilium `Neighbor soft reset out` | Already tried in #661; soft resets are frequent and non-diagnostic; UniFi peer stayed established. |
| unpoller / Grafana | No route/BGP series. |
| Dual-node tcpdump / CT (cluster side) | Detects **symptoms** (wrong-node ACK/RST), not UniFi’s hash decision. |
| API “which next hop for five-tuple X?” | **Does not exist** on probed surfaces. |

**Honest answer:** a pure hash flip with an unchanged multipath set is **not observable** from UniFi with the APIs and exporters we have. We can only see topology membership, not per-flow selection or selection changes.

## What WOULD be needed (for option 1 to become a real decision)

Any one of these would unblock measurement; none are present today:

1. **UDM FRR / VTY or shell access** (or UniFi UI/API equivalent) to read:
   - `ip route` / fib for `10.169.10.15` with hash policy
   - whether resilient/consistent hashing exists and is on
   - BGP update / route-replace logs with timestamps
2. **Per-flow or sampled forwarding telemetry** that names the chosen next hop for `client:port -> 10.169.10.15:22` (sFlow/IPFIX with nexthop, or firewall session table with gateway).
3. **A UniFi/controller API** that exposes BGP neighbor events and RIB history (not just the current routes snapshot).
4. **If affinity cannot be proven:** treat option 1 as blocked and choose option 2 (single advertiser) or 3 (`externalTrafficPolicy: Cluster`) knowing we are changing design without UniFi-side confirmation of the hash.

Optional low-cost cluster-side monitor (does not fix the gap): cron/poll `/v2/.../routes` for `10.169.10.15/32` and alert if next-hop set ≠ `{.118,.119}` or `in_use` flips. That watches **withdrawals**, not re-hashes.

## Impact on the #677 remedy table

| Option | After this investigation |
|--------|---------------------------|
| 1. Upstream affinity / resilient ECMP | **Blocked on missing observability + unknown UniFi hash controls.** Can confirm multipath is active; cannot verify or tune live-flow affinity from here. |
| 2. Single advertising node | Still viable; does not need UniFi hash visibility. |
| 3. `externalTrafficPolicy: Cluster` | Still viable; does not need UniFi hash visibility; source-IP trade-off unchanged. |

## What I did / did not do

- Read-only API GETs and unpoller `/metrics` scrape.
- Used existing `external-dns-unifi-secret` API key (not printed).
- Did **not** change UniFi, FRR, SNMP, firewall, or Kubernetes traffic policy.
- Did **not** open SSH/SNMP on the UDM.
- Did **not** merge anything.
