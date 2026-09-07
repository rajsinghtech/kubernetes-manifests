# #677 — out-of-repo IP consumer audit

Read-only. Closes the gap named in `677-ecmp-decision-memo.md`: whether any
IP ban / geo / rate-limit system outside SecurityPolicy manifests would break
if the public VIP stops preserving real client source IPs (option 3).

## Verdict

**No load-bearing IP allow/deny/ban/geo consumer was found on the public VIP
path.** Option 3 moves from “probably safe for authZ” to **safe for
authorization and abuse controls we can inventory**. Remaining cost is still
**observability** (Envoy `downstream_remote_address` / XFF become node IPs).

Checked surfaces below. Residual unknown is only something entirely outside
this fleet (e.g. a human paste of IPs into an ISP ticket) — not an automated
control in GitOps, UniFi, Tailscale, Forgejo, Zot, tinyauth, or the cluster.

---

## 1. Cloudflare / CDN / WAF

Cloudflare in this repo is **authoritative DNS + DNS-01**, plus DDNS and a
Robbinsdale `cloudflared` tunnel. Architecture doc: orange-cloud for some
public names; DNS-only for others.

For the names that matter to #677 / #661:

| Name | `cloudflare-proxied` | Resolves via |
|------|----------------------|-------------|
| `bhaiya.keiretsu.top` | **false** | CNAME → `ottawa.keiretsu.top` → WAN → UniFi DNAT → `10.169.10.15` |
| `*.bhaiya.keiretsu.top` | **false** | same |
| `forgejo.keiretsu.top` | **false** | same (pinned off GSLB) |
| apex / `www.keiretsu.top` | true | CF edge → GSLB (not the SSH VIP path) |

Live `dig`: `bhaiya` / `forgejo` → `ottawa.keiretsu.top` → `76.71.102.41`
(WAN), not Cloudflare anycast. SSH `:22` hits UniFi port-forward
`Envoy Public` → `10.169.10.15` with `src: null` (any).

**No Cloudflare WAF / Access / IP ruleset manifests** under
`kubernetes/apps/base/cloudflare` (ExternalDNS + DDNS + probes only).
St. Petersburg has a commented Cf-Access email header example for OpenWebUI —
not Ottawa public VIP, not IP-based.

**Cluster does not put SSH or bhaiya HTTP behind a CF IP WAF.** Losing real
client IP at Envoy does not bypass or break a CF IP rule that is not in front
of this path.

---

## 2. UniFi firewall / traffic rules

API key read-only against `192.168.169.1`:

| Object | Result |
|--------|--------|
| `rest/firewallrule` | **empty** `data: []` |
| `v2/.../trafficrules` | **empty** `[]` |
| `rest/firewallgroup` | 4 groups: port groups `web`/`Envoy`; address groups `envoy`=`10.169.10.15`, `k8s`=`10.169.10.15`+`.53` — **VIP destinations, not client ban lists** |
| `rest/portforward` | `Envoy Public` DNAT WAN→`10.169.10.15` ports `443,80,22,8555`, **`src: null`** (any source) |
| IPS/alarm stats endpoints | 404 on this controller |

No source-IP firewall rules, no traffic rules, no IPS event API on this box
via the Network API we can call. Port-forward is destination VIP, open source.

---

## 3. fail2ban / CrowdSec / similar

- Cluster-wide pod/deploy search: **no** fail2ban, crowdsec, modsec, banhammer
  workloads.
- Repo grep: no fail2ban/crowdsec app.

Not present as an in-cluster consumer of Envoy/SSH IPs.

---

## 4. Tailscale ACLs

`tailscale/policy.hujson`: grants are **identity/tag/group** based
(`@github`, `tag:*`, `group:*`). `ipset:*` entries are **LAN/pod CIDR
destinations** for subnet-router `via` grants (`192.168.169.0/24`,
`10.169.0.0/16`, etc.), not public-client allow/deny lists.

No ACL keys on residential client IPs such as `65.35.213.179`. Tailscale path
already survived the A/B and is outside this VIP’s Local+ECMP pair.

---

## 5. Forgejo

`security.REVERSE_PROXY_TRUSTED_PROXIES` = cluster pod CIDRs only
(`10.2/16`, `10.3/16`, localhost). Registration locked to external/OpenID;
no IP allowlist / fail2ban settings in the Helm values we ship.

Forgejo SSH for git may share the public `:22` listener mux — auth remains
Forgejo credentials/keys, not peer IP bans in this config.

---

## 6. Zot

Service `sessionAffinity: ClientIP` appears in the HelmRelease — that is
**Kubernetes session stickiness**, not an abuse IP ACL. Auth is S3/Garage
credentials for the registry backend. No IP ban config in the zot app tree.

---

## 7. tinyauth

`tinyauth.env` documents an **authN allowlist of Google accounts** (emails),
not IPs. Deployments have no rate-limit/geo/IP-ban env. SecurityPolicies use
tinyauth for email injection only.

---

## 8. Log parsers / alert-driven blockers

- Mimir rules under `bhaiya*` / monitoring: no alerts that match
  `downstream_remote_address` / `client_ip` to trigger blocks.
- Envoy access logs **record** `downstream_remote_address`; nothing in-repo
  **acts** on that field for deny.
- No Alloy/river pipeline found that feeds Envoy client IPs into a ban API.

So “invisible rate limiter reading Envoy logs” is **not** present in GitOps or
running ban workloads. A human grepping logs remains possible and is outside
automated control.

---

## Relation to option 3

| Concern from memo | After this audit |
|-------------------|------------------|
| AuthZ break | Still **none** (email/SSH key) |
| Unknown IP ban/geo | **None found** in CF path, UniFi, Tailscale, Forgejo, Zot, tinyauth, fail2ban/CrowdSec, or log-acting alerts |
| Observability | Still lost under Cluster — accepted separately |

**Decision impact:** the memo’s “declare out-of-repo consumers before Cluster”
gate is cleared for everything we can inventory. Raj can treat option 3 as
**safe for access control**, with the remaining trade-off explicitly
forensics/telemetry only.
