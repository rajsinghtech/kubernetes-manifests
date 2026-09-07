# Architecture reference

This is the detailed companion to the three architecture diagrams in
[`README.md`](../../README.md#architecture). The diagrams show mechanism — what
talks to what, and which way causality runs. This document carries the
operational detail that used to be crammed into their node labels, which is
what made them unreadable. Come here when you need the *why*: the version pins
that are deliberate, the settings that exist because something broke, and the
constraints that are not obvious from reading a manifest.

For the flat list of what is deployed where — every cluster, machine, namespace
and Flux Kustomization — see [`inventory.md`](inventory.md), which is generated
from the tree by `tools/gen-inventory.sh` and so cannot drift.

**Contents**

| Section | Go here when you are asking |
|---|---|
| [Outside world](#outside-world) | who we depend on that we do not run |
| [Delivery pipeline](#delivery-pipeline) | why my change has not taken effect |
| [Tailnet overlay](#tailnet-overlay) | why one cluster cannot reach another — start with [the egress contract](#the-pod-side-tailnet-egress-contract) |
| [North-south ingress](#north-south-ingress) | why a hostname does not resolve, or serves the wrong thing |
| [Storage and data](#storage-and-data) | where the bytes are, and which failure loses them |
| [Observability](#observability) | where the metrics and logs went |
| [Workloads](#workloads) | what actually runs, and what it depends on |
| [The cluster network underneath all of this](#the-cluster-network-underneath-all-of-this) | why an address is reachable at all, and what that exposes |
| [What breaks when a site goes down](#what-breaks-when-a-site-goes-down) | blast radius, and which failures are survivable |
| [Upgrades and operational ordering](#upgrades-and-operational-ordering) | the sequences that break things when done out of order |
| [Per-cluster facts](#per-cluster-facts) | the specifics of one site |

---

## Outside world

Everything in this section is run by someone else. It is the boundary the repo
negotiates with.

**People.** Two populations: browsers on the public internet, and tailnet
devices (laptops, phones) that reach services over the overlay.

**Cloudflare.** Authoritative DNS for every zone. It is a proxied
("orange-cloud") edge for public names, and DNS-only for tailnet and GSLB
names. It is also the DNS-01 solver target for every certificate.

**Let's Encrypt.** Issues every gateway certificate via ACME DNS-01 through the
Cloudflare API. There is no HTTP-01 path anywhere.

**Tailscale control plane.** Coordination plus MagicDNS for the tailnet
`keiretsu.ts.net`. An OAuth client authorises the in-cluster operator to create
devices. The ACL policy is pushed from `tailscale/policy.hujson` in this repo.

**GitHub — `keiretsu-labs/kubernetes-manifests`.** The `main` branch is the
only durable state in the system. GitHub Actions and Renovate run here, and the
Actions runner scale sets dial *out* from each cluster (no inbound path is
required).

**Upstream artifact sources.** OCI and Helm artifacts come from `ghcr.io`,
`quay.io`, `docker.io` and `registry.k8s.io`, declared as `HelmRepository` and
`OCIRepository` objects under `clusters/common/flux/repositories`. Git sources
include `github.com/firecrawl/firecrawl`, `csi-addons`, `garage`, `valkey-helm`
and `tailscale-examples`.

---

## Delivery pipeline

The pipeline is identical in all three clusters. Only the location string
changes.

### From author to merge

A change is written either by a human or by a pi build agent driven by
`tools/agent/pi-task.sh` (backend `aperture/deepseek-v4-flash`).

The local gate must pass before commit:

| Command | What it checks |
|---|---|
| `tools/check.sh [cluster]` | CI-pinned Flate changed-only render of all three clusters |
| `tools/check-versions.sh` | `talconfig` ↔ tuppr, `CephCluster` ↔ toolbox |
| `tools/orphans.sh` | kustomization ↔ disk drift |
| `tools/check-diagram.sh` | the architecture docs: syntax, secrets, staleness, coverage, links |
| `tools/gen-inventory.sh` | regenerates `docs/reference/inventory.md` from the tree |
| `tools/tests/run.sh` | offline self-tests for `tools/` |
| `make diff` | rendered diff vs `origin/main` |

GitHub Actions workflows — seventeen on disk:

- `flate.yaml` — render matrix plus a sticky rendered-diff comment per cluster
- `validate.yaml` — YAML parse gate on Renovate PRs
- `version-sync.yaml` — coupled-version enforcement
- `diagram.yaml` — `tools/check-diagram.sh` plus the rendered SVGs as an artifact
- `tailscale.yml` — syncs `policy.hujson` to the tailnet
- `tailscale-full-config-status.yml` — reports the tailnet's full-config state
- `api-tailnet-k8s-test.yml` — ephemeral-tailnet operator E2E
- `delete-inactive-tailnet-nodes.yml` — tag-filtered device reaping
- `token.yml`, `release.yaml`, `label-sync.yaml`, `devcontainer.yaml`
- `garage-webadmin-build.yaml`, `garage-webadmin-sidecar-build.yaml`
- `aqua-checksums.yaml`, `swarm-test.yaml`, `test-arc-runner.yaml`

The first three of those are worth a caveat: `flate.yaml`, `diagram.yaml` and
`version-sync.yaml` are **path-filtered**, not unconditional. `flate` fires only
on `clusters/**` or `kubernetes/**`; `diagram` on those plus the README, the
`docs/diagrams` and reference docs and the three diagram/inventory tools; and
`version-sync` on an explicit list of version-coupled paths. A PR that touches
nothing on a workflow's list shows that workflow as absent rather than green —
so "no red checks" is not the same as "the render gate passed", which is the
reason to run `tools/check.sh` locally regardless.

**Renovate.** Groups defined in `.renovate/`: `talos-<loc>`, `rook-<loc>`,
`ceph-<loc>` and friends. One PR per cluster per subsystem, so two sites never
roll at once.

### From merge to running infrastructure

**`GitRepository kubernetes-manifests`** — branch `main`, interval 30m. Its
ignore filter excludes everything and then re-admits `clusters/common`,
`clusters/talos-<location>` and `kubernetes/`; Robbinsdale and St. Petersburg
additionally re-admit `/swarm` and `/laptop`, so those two clusters pull a
slightly wider tree than Ottawa does.

The three clusters also differ in **how they authenticate**: only Ottawa carries
a `secretRef` (`kubernetes-manifests-github-token`). Robbinsdale and
St. Petersburg have no `secretRef` at all and fetch anonymously over HTTPS,
which works only because the repository is public — make it private and those
two stop reconciling while Ottawa carries on, which is a confusing failure to
diagnose from the symptom.

**SOPS decryption** — PGP key `FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5`, with
the in-cluster half in Secret `sops-gpg`. It encrypts `data`/`stringData` in
`*.sops.yaml` files.

Three top-level Kustomizations:

| Kustomization | Path | Supplies |
|---|---|---|
| `cluster` | `clusters/talos-<location>/flux` | `cluster-settings` / `cluster-secrets`, `cluster-user-settings` / `-secrets` |
| `common-cluster` | `clusters/common/flux` | Helm/OCI/Git sources, `common-settings` + `common-secrets` |
| `kubernetes-apps` | `kubernetes/apps/<location>` | prune true, wait false, interval 30m; patches every child Kustomization with the `substituteFrom` stack and SOPS decryption |

### The `postBuild.substituteFrom` stack

Every pointer inherits all seven entries, in order:

1. ConfigMap `common-settings` — `COMMON_DOMAIN`, `K8GB_EXT_GEO_TAGS`,
   `GARAGE_*` defaults
2. Secret `common-secrets`
3. ConfigMap `cluster-settings` — `LOCATION`, `SITE_ID`, `FAILOVER`,
   `TIMEZONE`, the CIDRs, `CLUSTER_DOMAIN`, `STORAGECLASS_*`,
   `COMMON_S3_ENDPOINT`, `GARAGE_NODE_LOCAL_POOLS`
4. Secret `cluster-secrets`
5. ConfigMap `cluster-user-settings` (optional)
6. Secret `cluster-user-secrets` (optional)
7. Secret `garage-keiretsu-bucket` (optional)

Opt out with the label `substitution.flux.home.arpa/disabled=true`.

Substitution is **single pass**: a `$` inside a substituted value is *not*
re-expanded. In raw manifests that Flux renders, write `$${VAR}` to emit a
literal `${VAR}`.

### Pointer and base convention

One pointer per app per cluster lives at
`kubernetes/apps/<location>/<ns>/<app>.yaml`, with
`spec.path` → `kubernetes/apps/base/<ns>/<app>[-<location>]`. **The pointer's
existence IS the deployment decision**, and its `metadata.name` is the app
identity.

`kubernetes/apps/base/<ns>/<app>/` holds the real manifests, written exactly
once. Split into `<app>-<location>` only when the config truly differs.
`kubernetes/components/` holds reusable Kustomize components.

### Sources other than this repo

Three apps are reconciled from a `sourceRef` other than `kubernetes-manifests`,
which is why a change here can be perfectly committed and still not move them:

- `GitRepository bhaiya` → `forgejo.keiretsu.top/corp/bhaiya.git` (self-hosted
  Forgejo). This repo owns only the GitRepository, `forgejo-bhaiya` credentials,
  and the Flux Kustomization pointer (no `targetNamespace`). The Receiver,
  webhook token, Firefly MCP ExternalSecret, and home Gateway editor RBAC live
  in `corp/bhaiya`'s activation overlay. Ottawa only.
- `GitRepository firecrawl` → `github.com/firecrawl/firecrawl`, path
  `./examples/kubernetes/cluster-install`. Ottawa only.
- `GitRepository csi-addons` → the upstream project, path `./deploy/controller`,
  `dependsOn` `rook-ceph-operator`. Deployed in **Ottawa and Robbinsdale** —
  the two clusters with Ceph. Only its *configuration* (`csi-addons-config`)
  comes from this repo, so an upstream tag bump changes the controller without
  any commit here.

### Notifications and bootstrap

`flux-notifications` holds Providers and Alerts, with webhook targets
SOPS-encrypted. GitHub commit status is driven by the label
`notifications.keiretsu.top/github-status`. `flux-monitoring` supplies
controller ServiceMonitors and dashboards.

The one-time bootstrap in `clusters/common/bootstrap/flux/` (Flux controllers
and CRDs) is **never reconciled by Flux**. After bootstrap,
`clusters/talos-<location>/flux/config/cluster.yaml` takes over and creates the
three Kustomizations above.

---

### Deleting a pointer deletes the objects

The delivery section's headline is that a pointer file's existence is the deploy
decision. The converse deserves saying out loud: all three top-level
Kustomizations run with `prune: true`, so **removing a pointer does not just
stop managing its objects, it deletes them.**

The guard is the annotation `kustomize.toolkit.fluxcd.io/prune: disabled`, which
114 files in the tree carry. It is on exactly the things you would not want a
mistaken `git rm` to destroy — Ottawa's `CephCluster`, `CephBlockPool`,
`CephFilesystem` and snapshot classes among them — alongside
`preserveFilesystemOnDelete: true` on the CephFilesystems. Robbinsdale's Ceph
config does **not** carry those guards, which is worth knowing before pruning
anything there.

Namespaces owned by an app keep the same annotation, which is why the add-app
checklist says to leave it alone.

Retiring a protected namespace takes one extra reconciliation. First leave the
Namespace in the rendered output and remove its
`kustomize.toolkit.fluxcd.io/prune: disabled` guard; let Flux apply that change.
Only a later revision should remove the Namespace manifest and its location
pointer, so the parent `kubernetes-apps` Kustomization can prune the now-
unprotected object. If both were removed in one revision, Flux cannot clear a
guard from an object that is no longer in its desired set. After verifying an
orphan is empty, the operator must perform the one-time deletion with the
cluster helper and must not strip finalizers:

~~~bash
tools/kc.sh ot get namespace border0
tools/kc.sh ot -n border0 get all
tools/kc.sh ot delete namespace border0
~~~

## Tailnet overlay

The tailnet `keiretsu.ts.net` is the only path between clusters. Every
cross-cluster dependency rides it.

### `tailscale/policy.hujson` — central zero-trust policy

- **groups** — `group:superuser` plus one group per location.
- **tags** — `tag:infra`, `tag:k8s`, `tag:k8s-operator`, `tag:k8s-recorder`,
  `tag:ci`, `tag:ssh-granted`, plus per-location (`tag:ottawa`,
  `tag:robbinsdale`, `tag:stpetersburg`) and per-person (`tag:raj`,
  `tag:kartik`) tags. There is **no `tag:lobby`** in `tagOwners` — the word
  does not appear in `policy.hujson` at all, because lobby lives on a separate
  personal tailnet that this policy does not govern.
- **ipsets** — one per location (LAN /24 plus the service/pod/LB /16s), plus
  `ipset:infrastructure` = the three 4via6 /96 ranges.
- **autoApprovers** — routes, exit nodes and Tailscale Services for `tag:k8s`.
- **ssh** — recorded sessions enforced through `tag:k8s-recorder`.
- **grants** — location-to-location access only via that location's own subnet
  router; capability grants for `cap/relay`, `cap/kubernetes` (impersonation),
  `cap/tsidp`, and a custom `cap/tsdnsproxy` DNS-rewrite map.
- **nodeAttrs** — traffic-steering and app-connector domain sets; funnel for
  `tag:k8s`.
- **tests** and **sshTests** are committed alongside and run in CI.

### Operator and its objects

**`tailscale-operator`** (chart 1.102.2), one per cluster. Hostname
`${LOCATION}-k8s-operator`; `defaultTags` `tag:${LOCATION}` +
`tag:k8s-operator`; proxy devices tagged `tag:k8s` + `tag:${LOCATION}`.
`apiServerProxyConfig` runs with `mode=true` and `allowImpersonation=true`. The
`operator-oauth` Secret is SOPS-encrypted.

**`Connector ${LOCATION}-subnetrouter`** (2 replicas) advertises `LAN_CIDR`
plus the service, pod and LoadBalancer CIDRs, plus 4via6
`fd7a:115c:a1e0:b1a:0:${SITE_ID}::/96`. An `exitNode` stanza is present but
commented out.

**`Connector ${LOCATION}-appconnector`** (2 replicas) is the app connector for
the 4via6 range; its domain sets are declared in the policy's `nodeAttrs`.

**`ProxyGroup common-egress`** (egress, 3 replicas, proxyClass
`common-accept-routes`) backs *every* `tailscale.com/tailnet-fqdn`
ExternalName Service.

**`ProxyGroup common-ingress`** (ingress, 3 replicas, proxyClass
`${TAILSCALE_INGRESS_PROXY_CLASS}` = `common-dev`).

**`ProxyGroup ${LOCATION}-k8s`** (kube-apiserver, 2 replicas) runs
`kubeAPIServer.mode: auth`. This is what serves
`<location>-k8s-operator.keiretsu.ts.net:443`. Tailnet identity is the
credential; the repo kubeconfig carries no keys — only operator URLs and
`token: unused`.

**ProxyClasses:**

| Name | What it adds |
|---|---|
| `common` | metrics + ServiceMonitor, `priorityClassName: infra-high`, topology spread over `kubernetes.io/hostname` |
| `common-accept-routes` | `common` plus `acceptRoutes=true` |
| `common-dev` | `common` plus a custom `tun-service-metrics` image (the ingress default) |
| `common-unstable` | `common` pinned to a Tailscale unstable tag |
| `common-userspace` | **not** built on `common` — it sets only `TS_USERSPACE=true` and drops all capabilities on both containers. No metrics, no ServiceMonitor, no `infra-high`, no topology spread. Spare; a proxy moved onto it silently disappears from monitoring |

**`DNSConfig ts-dns`** (2 nameserver replicas). Service `ts-dns` is type
LoadBalancer, UDP+TCP 53 → 1053, pinned at `<LB CIDR>.69.50` per cluster.
CoreDNS forwards `ts.net` here so pods resolve tailnet names. **It only
publishes names backed by an egress Service** — not every MagicDNS device.

**`PeerRelay ${LOCATION}`** (1 replica) — StatefulSet `peerrelay-${LOCATION}`,
device `<location>-peer-relay-0`, UDP 41641. Its VIP is pinned via the
`lbipam.cilium.io/ips` annotation at `<LB CIDR>.100.100`, because PeerRelay
Services cannot use `spec.loadBalancerIP`. Authorised by the `cap/relay` grant.

**`Recorder ${LOCATION}-recorder`** (1 replica) — `tsrecorder` v1.102.2, UI
enabled, tags include `tag:k8s-recorder`. It receives the SSH sessions the
policy forces to be recorded. Its `storage.s3` stanza is currently commented
out, so there is no live sink.

**`tailscale-csi-provider`** (DaemonSet) — a Secrets Store CSI provider plus
`SecretProviderClass tailscale`, letting pods mount tailnet auth material
instead of Kubernetes Secrets.

**`tailscale-system-app`** — companion workloads, not the operator:

- `tsdnsproxy` maps `<location>.k8s` names onto in-cluster DNS and rewrites to
  `svc.cluster.local` (the `cap/tsdnsproxy` grant).
- `tsddns` — CronJob `*/45 * * * *`. Read that as it fires, not as the name
  suggests: a step of 45 over a 0–59 minute field means **:00 and :45 only**,
  so the real gap alternates 45 minutes then 15. Not "every 45 minutes".
- `log-streaming` — CronJob `17 * * * *`, shipping tailnet audit logs to
  Garage S3.
- `rbac` and `secret` provide supporting RBAC; the per-node DaemonSet stays
  disabled.

**`tailscale-examples`:**

- `tailscale-examples-sandbox` — the Kustomization runs in **Ottawa and
  Robbinsdale**, not Ottawa alone. What it actually renders is `tsflow`,
  `tsk9s` and a secret: `tsidp` (OIDC identity provider, hostname
  `${LOCATION}-idp`), `golink`, `derper`, `proxyt`, `tsddns`, `egress` and
  `vector` are all **commented out** of its `kustomization.yaml`, so their
  manifests are on disk and in neither cluster.
- `tailscale-service-repro` — operator reproduction case (Ottawa)

`tempvm` is **not** part of this group — it lives in its own namespace at
`kubernetes/apps/base/tempvm/tempvm/app/` (Ottawa), and it is not a Tailscale
`svc:` Service either: it is a plain Service with
`loadBalancerClass: tailscale` and `tailscale.com/hostname: tempvm`, i.e. the
operator gives it its own tailnet **device**. That distinction matters, because
a device and a Tailscale Service are approved, ACL-matched and DNS-published in
different ways.

### The pod-side tailnet egress contract

This is the rule that keeps breaking people.

For every tailnet name a pod consumes, declare in the **consuming namespace**:

- a Service of type `ExternalName` with a placeholder `externalName`
- annotation `tailscale.com/tailnet-fqdn: <name>.keiretsu.ts.net`
- annotation `tailscale.com/proxy-group: common-egress`

The operator rewrites `externalName` to a `*.tailscale.svc.cluster.local`
proxy, and `DNSConfig` republishes the original `.ts.net` name as that proxy's
ClusterIP.

**Verify BOTH before wiring a client:**

1. the Service condition `TailscaleEgressSvcReady=True`
2. a throwaway pod resolves the `.keiretsu.ts.net` name

A laptop `dig` proves nothing — laptops use MagicDNS, pods do not.

Never publish tailnet CGNAT addresses in public DNS. The range is
`100.64.0.0/10`. <!-- diagram-check: allow — documents the range itself -->
The secret scanner in `tools/check-diagram.sh` rejects addresses from it, which
is why this one line carries an explicit allow marker.

Identity-authenticated protocols (Garage RPC) need one ingress identity and one
egress Service **per remote node**; a shared L4 VIP cannot route a node ID.

A kro `ResourceGraphDefinition serviceegress` generates this whole pattern as a
custom `ServiceEgress` resource (group `network.keiretsu.ts.net`).

---

## North-south ingress

Three gateway tiers, three DNS planes, certificates, authorization.

### Zones and who answers them

| Zone | Role | Answered by |
|---|---|---|
| `killinit.cc` | Ottawa's `${CLUSTER_DOMAIN}` | Cloudflare |
| `lukehouge.com` | Robbinsdale's `${CLUSTER_DOMAIN}` | Cloudflare |
| `rajsingh.info` | St. Petersburg's `${CLUSTER_DOMAIN}` | Cloudflare |
| `keiretsu.top` | `${COMMON_DOMAIN}`, shared | Cloudflare |
| `cdn.keiretsu.top` | public GSLB | delegated to k8gb |
| `ts.keiretsu.top` | tailnet GSLB | delegated to k8gb |

LAN views of the above are written into UniFi; tailnet views into Pi-hole.

### DNS plane 1 — Cloudflare, for the public tier

Four ExternalDNS instances per cluster (chart 1.21.1).

`external-dns-cloudflare-killinit-cc`,
`external-dns-cloudflare-lukehouge-com` and
`external-dns-cloudflare-rajsingh-info` each source
`gateway-httproute` / `-tlsroute` / `-tcproute` / `-udproute`, with
`--gateway-label-filter gateway==public`,
`--default-targets ${LOCATION}.<domain> --force-default-targets`, policy
`sync`, `txtOwnerId ${LOCATION}-<domain>` and
`txtPrefix k8s.${LOCATION}.<domain>.`.

`external-dns-cloudflare-keiretsu-top` uses source `crd` **only**, with
`--label-filter dns-target==cloudflare`, `txtOwnerId keiretsu-top-${LOCATION}`
and `txtPrefix k8s.keiretsu.top.`.

**Consequence worth memorising:** a `${CLUSTER_DOMAIN}` route gets DNS for free
the moment it attaches to a gateway labelled `gateway=public`. A
`${COMMON_DOMAIN}` name does **not** — it needs a hand-written `DNSEndpoint`
entry, or it will report `Accepted=True` forever and never resolve.

### DNS plane 2 — UniFi, for the private tier

`external-dns-unifi`, provider `webhook`, with a sidecar image
`external-dns-unifi-webhook` and a SOPS-encrypted UniFi API key. Filters:
`--gateway-label-filter external-dns==private` and
`--label-filter dns-scope!=public-only`. Sources: `crd` plus all four gateway
route kinds plus `service`. Policy `sync`.

The `dns-scope!=public-only` filter exists because the UniFi static-DNS API
rejects wildcard hostnames with `400 Invalid Hostname`, so the wildcard
`DNSEndpoint` is deliberately tagged out of this instance's view.

### DNS plane 3 — Pi-hole, for the tailnet tier

`ts-external-dns`, provider `pihole`, with
`--gateway-label-filter external-dns==ts`, sourcing the four gateway route
kinds **plus `service`** — so a LoadBalancer or ExternalName Service with the
right annotations also gets a Pi-hole record here, without any HTTPRoute —
`txtOwnerId ${LOCATION}-${CLUSTER_DOMAIN//./-}`,
`txtPrefix k8s.${LOCATION}.`, policy `sync`.

Pi-hole itself is reachable through the `ts` Gateway's `:53` TCP and UDP
listeners (`TCPRoute ts-pihole-tcp` / `UDPRoute ts-pihole-udp`).

### cloudflare-ddns

One per cluster domain. Keeps `${LOCATION}.<domain>` A/AAAA pointed at the
site's current WAN address. That record is the target every ExternalDNS CNAME
and every k8gb pool member ultimately resolves to.

### The two hand-written DNSEndpoints for `keiretsu.top`

Both live in `kubernetes/apps/base/k8gb/k8gb-common/config/cnames.yaml`.

**`keiretsu-top-cnames`** (label `dns-target=cloudflare`):

- Proxied through Cloudflare: the apex and `www` →
  `keiretsu.cdn.keiretsu.top`.
- Pointed at `<name>.cdn.keiretsu.top`, i.e. answered by k8gb GSLB:
  `velero`, `hubble`, `logs`, `prometheus`, `opencost`, `oci`,
  `status`, `s3`, `tailscale-logs.s3`.
- Pointed at `ottawa.keiretsu.top`, i.e. straight to the Ottawa edge and
  bypassing GSLB: `auth`, `home`, `bhaiya`, `forgejo`, `grafana`, `teslamate`, `litellm`,
  `woodpecker`, `infisical`, `frigate`, `monz`, `cliproxy`,
  `frigate.${LOCATION}`. `bhaiya` is pinned here on purpose — through the GSLB
  the second WAN edge 404s about half the time. `forgejo` is pinned for the
  same class of failure: public CNAME → `forgejo.cdn` follows k8gb NS
  `ns1.dns.cdn.keiretsu.top` which has no A glue, so in-cluster lookups via
  CoreDNS/NodeLocal (the `keiretsu.top` stub forwarded to a public recursor)
  NXDOMAIN and Woodpecker cannot POST `/login/oauth/access_token`. Ottawa
  CoreDNS/NodeLocal also answer `forgejo.keiretsu.top` as the public Envoy
  Gateway VIP and forward `cdn.keiretsu.top` to the site k8gb CoreDNS VIP so
  pods never wait on that glue.

**`keiretsu-top-wildcards`** (labels `dns-target=cloudflare`,
`dns-scope=public-only`):

- `*.bhaiya.keiretsu.top` and `*.hermes.keiretsu.top` → `ottawa.keiretsu.top`
- `*.${LOCATION}.keiretsu.top` → `${LOCATION}.keiretsu.top`

Everything is `cloudflare-proxied=false` except the apex/`www` pair.

### k8gb — GSLB for the shared zone

`clusterGeoTag ${LOCATION}`; `extGslbClustersGeoTags` =
`ottawa,robbinsdale,stpetersburg`. Load-balanced zones under parent
`keiretsu.top`:

- `cdn.keiretsu.top` — public multi-cluster names
- `ts.keiretsu.top` — tailnet-facing names

Negative TTL 30s, NS TTL 30s, requeue 60s; the edge resolver is a public
resolver. The bundled CoreDNS runs 3 replicas with priorityClass `infra-high`
and a LoadBalancer at `<LB>.10.53`. Gateway API integration is on; the
`extdns` sidecar is **off**, because the ExternalDNS instances above own
Cloudflare. An extra CoreDNS template answers
`_acme-challenge.cdn.keiretsu.top` so DNS-01 can still issue certificates for
GSLB names.

The `Gslb` count is **per cluster, not global**. Eleven come from the shared
`k8gb-common/config` Kustomization that every cluster deploys: `keiretsu-web`,
`dashboard-cdn`, `dashboard-ts-cdn`, `ts-gateway`, `garage-s3-cdn`,
`zot-public`, `forgejo`, `velero`, `hubble`, `opencost`, `gatus-status`. Ottawa
adds two more from Ottawa-only Kustomizations — `prometheus`
(`k8gb-prometheus-ottawa`) and `victoria-logs` (`k8gb-monitoring-ottawa`) —
for **thirteen in Ottawa and eleven** in Robbinsdale and St. Petersburg. That
asymmetry is deliberate: only Ottawa runs the stores those two names front.

**No `Gslb` uses a failover strategy.** Every one of them sets
`strategy.type: roundRobin` with an explicit per-cluster `weight` map, which is
how a name is steered — `forgejo` is `ottawa: 100, robbinsdale: 0,
stpetersburg: 0` (Ottawa-only in practice), while `ts-gateway` is a genuine
33/33/34 split. `cluster-settings` does define a `FAILOVER` variable, but k8gb
does not consume it; changing a name's cluster preference means editing that
name's `weight` map, not the variable.

**Two constraints learned the hard way:**

1. A `Gslb`'s HTTPRoute must name **exactly one** parent Gateway. Most routes
   satisfy that by naming one Gateway and letting hostname matching pick the
   listener — `components/cdn-site/httproute.yaml`, which generates the whole
   CDN tier, pins no `sectionName` at all. The single repo-wide use of
   `sectionName: wildcard-keiretsu-top-https` is in
   `k8gb-monitoring-ottawa/gslb-grafana.yaml`, a Grafana-specific workaround —
   do not copy it as the general pattern.
2. An **absent** HTTPRoute reads as healthy, so an inert route is deployed to
   every cluster to make per-cluster health actually drive pool membership.

### Envoy Gateway

Three GatewayClasses per cluster, all on controller
`gateway.envoyproxy.io/gatewayclass-controller`, each with its own `EnvoyProxy`
parameter object. Note that the `EnvoyProxy` is **not** always named after its
class: `home-ts`'s parameter object is called `ts`.

| GatewayClass | EnvoyProxy | Gateway | Where |
|---|---|---|---|
| `public` | `public` | `public` (ns `home`) | LB `<LB CIDR>.10.15` |
| `private` | `private` | `private` (ns `home`) | LB `<LB CIDR>.10.14` |
| `home-ts` | `ts` | `ts` (ns `home`) | published on the tailnet |

There are only **two** `ClientTrafficPolicy` objects, and neither is named after
a GatewayClass — they are named for the certificate family they front:

- `wildcard-lan` targets Gateways `public` **and** `private` (whole-Gateway,
  so every listener is covered)
- `wildcard-ts` targets Gateway `ts` **and one listener section**,
  `sectionName: wildcard-${CLUSTER_DOMAIN//./-}-https`

Both set the same body: `xForwardedFor.numTrustedHops: 1`, a 1h idle / 15m
stream-idle timeout, `requestID: PreserveOrGenerate` and HTTP/2 window tuning.
The consequence of that `sectionName` is easy to miss: the `ts` Gateway's other
listeners — `*.ts.keiretsu.top`, the `:80` HTTP listener, Pi-hole's `:53`
TCP/UDP pair and Forgejo's `:22` — get **no** client-IP detection and none of
those timeouts. If a tailnet route logs the Envoy pod's address instead of the
client's, or dies at the default idle timeout, that is why.

The Gateways are defined **once** in `kubernetes/apps/base/home/home/` and
reused unmodified by all three clusters through `${CLUSTER_DOMAIN}` /
`${LOCATION}` substitution — there is no per-cluster Gateway overlay.

Lua extension policies are enabled on the controller, and the controller is
deliberately rolled after config changes because it does not always pick them
up in place.

### Gateway `public` — Internet-facing, 14 listeners

Label `gateway=public` (what the Cloudflare ExternalDNS instances filter on);
annotation external-dns target `${LOCATION}.${CLUSTER_DOMAIN}`.

| Listener / hostname | Proto | Port | Certificate secret |
|---|---|---|---|
| `http` | HTTP | 80 | — |
| `*.killinit.cc` | HTTPS | 443 | `wildcard-killinit-cc` |
| `*.lukehouge.com` | HTTPS | 443 | `wildcard-lukehouge-com` |
| `*.rajsingh.info` | HTTPS | 443 | `wildcard-rajsingh-info` |
| `*.keiretsu.top` | HTTPS | 443 | `wildcard-keiretsu-top` |
| `keiretsu.top` (bare apex) | HTTPS | 443 | `wildcard-keiretsu-top` |
| `*.hermes.keiretsu.top` | HTTPS | 443 | `wildcard-hermes-keiretsu-top` |
| `*.${LOCATION}.keiretsu.top` | HTTPS | 443 | `wildcard-ottawa-keiretsu-top` |
| `*.bhaiya.keiretsu.top` | HTTPS | 443 | `wildcard-bhaiya-keiretsu-top` |
| `*.cdn.keiretsu.top` | HTTPS | 443 | `wildcard-cdn-keiretsu-top` |
| `*.s3.keiretsu.top` | HTTPS | 443 | `wildcard-s3-keiretsu-top` |
| `forgejo-ssh` | TCP | 22 | TCPRoute only |
| `webrtc-tcp` | TCP | 8555 | Frigate live view, Ottawa only |
| `webrtc-udp` | UDP | 8555 | Frigate live view, Ottawa only |

**The eighth listener looks wrong and is not.** The hostname is parameterised
per cluster while the certificate reference is the literal name
`wildcard-ottawa-keiretsu-top` — but that Secret is written by Certificate
`wildcard-location-keiretsu-top`, whose `dnsNames` *are* parameterised. So
every cluster stores its own `*.<location>.keiretsu.top` certificate under a
name that says `ottawa`: correct behaviour, misleading name. Repointing the
listener alone would aim it at a Secret that nothing writes.

### Gateway `private` — site-private, 6 listeners

Labels `external-dns=private`, `gateway=private`.

| Listener / hostname | Proto | Port |
|---|---|---|
| `http` | HTTP | 80 |
| `*.killinit.cc` | HTTPS | 443 |
| `*.lukehouge.com` | HTTPS | 443 |
| `*.rajsingh.info` | HTTPS | 443 |
| `*.keiretsu.top` | HTTPS | 443 |
| `forgejo-ssh` | TCP | 22 (TCPRoute only) |

The Strimzi TLSRoutes *aim* at this tier and miss. They name Gateway `private`
in namespace **`envoy-gateway-system`**, plus `sectionName: kafka-listener` —
and no Gateway exists in that namespace. The real `private` Gateway lives in
`home` (as the table above shows) and has no `kafka-listener` section either,
so both halves of the reference are wrong and the routes are dangling. They
cost nothing today because the Strimzi pointer is commented out, but they will
not attach if it is ever switched on.

Narrower than `public` on purpose: no hermes / bhaiya / cdn / s3 / location
sub-tiers and no WebRTC, because LAN traffic never needs them. Not published to
Cloudflare — it lacks the `gateway=public` label.

### Gateway `ts` — tailnet only, 8 listeners

Label `external-dns=ts`.

| Listener / hostname | Proto | Port | Notes |
|---|---|---|---|
| `*.killinit.cc` | HTTPS | 443 | |
| `*.lukehouge.com` | HTTPS | 443 | |
| `*.rajsingh.info` | HTTPS | 443 | |
| `*.ts.keiretsu.top` | HTTPS | 443 | `wildcard-ts-keiretsu-top` |
| `http` | HTTP | 80 | |
| `pihole-udp` | UDP | 53 | `UDPRoute ts-pihole-udp` |
| `pihole-tcp` | TCP | 53 | `TCPRoute ts-pihole-tcp` |
| `forgejo-ssh` | TCP | 22 | TCPRoute |

It does **not** serve `*.keiretsu.top` — only `*.ts.keiretsu.top`. A route
whose hostname matches no listener reports `NoMatchingListenerHostname`, so
check first:

```bash
tools/kc.sh ot -n home get gateway ts -o jsonpath='{.spec.listeners[*].hostname}'
```

### How routes are actually distributed

- **private + ts** — the default for admin consoles: every `*arr`, `sabnzbd`,
  the two qBittorrents, `plex`, `prowlarr`, `garage-webui`, `headlamp`,
  `hubble`, per-cluster `grafana`/`prometheus`/`alertmanager`,
  `victoria-logs`, the Rook dashboard, `k9s`.
- **public as well** — `overseerr`, `tautulli`, `wizarr`, `plex`, and the
  Ottawa-only reading apps (`audiobookshelf`, `bookorbit`, `komga`,
  `suwayomi`).
- **public only** — the CDN tier: every route in namespace `keiretsu-top`,
  generated from the `components/cdn-site` template, which rewrites the Host
  header and sends traffic to `garage-gateway`.
- **Three Homers** — `dashboard-private`, `dashboard-public` and
  `dashboard-ts` are three separate deployments sharing the hostname
  `home.${CLUSTER_DOMAIN}`, one per tier. The `homepage` app additionally
  serves `home.keiretsu.top`.
- **Redirects** — the Flux Kustomization is called `grafana-redirect` in both
  places (Robbinsdale, ns `home`; St. Petersburg, ns `monitoring`); only the
  base directory differs, `home/grafana-redirect/app` versus
  `monitoring/grafana-redirect-stpetersburg`. Both attach to all three tiers
  and 301 `grafana.<cluster domain>` to the canonical `grafana.keiretsu.top`.
- **kro `approute`** — a `ResourceGraphDefinition` that generates
  Homer-annotated HTTPRoutes from a short schema, for self-service exposure.

Per-cluster divergences: Frigate is WAN-reachable only from Ottawa (it owns the
WebRTC routes); the Rook dashboard is ts-only on Ottawa but private+ts on
Robbinsdale; Plex adds the `ts` tier only on Robbinsdale; Home Assistant's
overlays drop the public tier the base template offers.

### cert-manager

ACME DNS-01 through Cloudflare, exclusively. ClusterIssuers in the shared base:

- `keiretsu-top` — `cnameStrategy: Follow`
- `keiretsu-top-nofollow` — no CNAME follow, to work around bhaiya wildcard
  shadowing
- `killinit-cc`, `lukehouge-com`, `rajsingh-info`
- `internal` — a **CA** issuer (`spec.ca`), not a self-signed one. It signs
  from a supplied key pair in Secret `kubernetes-internal-ca-key-pair`, which
  the repo does not create — so losing that Secret breaks every internal
  certificate, and there is no `SelfSigned` issuer anywhere to fall back on.

Robbinsdale adds exactly **one** issuer of its own — `luke-issuer`, plus the
`cloudflare-luke` token Secret it needs; everything shared (`keiretsu-top`,
`killinit-cc`, `lukehouge-com`, `rajsingh-info`, `internal`) comes from
`cert-manager-common/issuers`, which Robbinsdale also deploys. The naming drift
is still worth knowing: `luke-issuer` and `cloudflare-luke` do the same job as
the shared `lukehouge-com` issuer under different names.

Wildcard Certificates back every listener secret named above, plus the Kafka
server certificate. All Cloudflare API tokens and ACME account keys are
SOPS-encrypted.

### Authorization — Tinyauth authenticates, SecurityPolicy authorises

| Deployment | Role |
|---|---|
| `tinyauth` | serves `auth.keiretsu.top` (Ottawa) |
| `tinyauth-killinit` | serves `auth.killinit.cc` — suwayomi needs a cookie scoped to `killinit.cc`, not the shared `keiretsu.top` one |
| `tinyauth-ts` | a Tailscale Service in front of the same pods |
| `tinyauth-egress` | Robbinsdale and St. Petersburg run no local Tinyauth; a headless Service plus pinned Endpoints reaches the Ottawa instance across the tailnet |

Tinyauth only **authenticates** (Google) and injects `Remote-User`,
`Remote-Email`, `Remote-Name` and `Remote-Groups`. Every protected route then
carries its own Envoy Gateway `SecurityPolicy` with `extAuth` pointing at the
`tinyauth` Service and an `authorization` block that is `defaultAction: Deny`
plus an explicit `Remote-Email` allow-list. There is no central role model —
access is per-route, per-person, and visible in the manifest.

**`ReferenceGrant extauth-to-tinyauth` is not the same object in every
cluster**, and this is a real trap. The name is shared; the contents are not.

| Where | Admits SecurityPolicies from |
|---|---|
| Ottawa (`auth/tinyauth`) | `home`, `bhaiya`, `keiretsu-top`, `velero-system`, `teslamate`, `monz`, `cliproxy`, `media` |
| Robbinsdale, St. Petersburg (`tinyauth-egress`) | `home` and `keiretsu-top` **only** |

So a SecurityPolicy copied from Ottawa into `media` or `monitoring` on the other
two clusters is refused for want of a grant, and the symptom is an unprotected
or broken route rather than an obvious error on the policy itself. Widen the
local grant when you extend extAuth past `home`/`keiretsu-top`.

Ottawa carries a second, narrower grant as well: `extauth-to-tinyauth-killinit`
admits only `media`, pointing at the `tinyauth-killinit` Service — currently
just Suwayomi.

An `EnvoyExtensionPolicy` carries a few lines of Lua that turn Tinyauth's 401
(which carries an `x-tinyauth-location` header) into a 302 so browsers follow
the login flow. It is duplicated on `homepage`, `cliproxy`, `frigate` and
`grafana-cdn`.

`kromgo` is intentionally unauthenticated on the public tier — it serves only
the badge endpoints the README renders. Tailnet-only routes rely on tailnet
policy instead of Tinyauth.

### cloudflared

Robbinsdale only. An outbound-only Cloudflare tunnel, so Robbinsdale can
publish without an inbound port forward — an ingress path that bypasses its
Envoy public tier.

---

## The cluster network underneath all of this

Every address the ingress and tailnet sections cite — the pinned Gateway
LoadBalancer IPs, the DNS nameserver IP, the PeerRelay VIP — only reaches the
LAN because of Cilium. It is worth knowing how, because nothing else in this
document explains why a `LoadBalancer` Service gets an address or how that
address becomes routable.

### Cilium is the one component that is fully per-cluster

Talos ships with no CNI (`cni: none`) and kube-proxy disabled; Cilium is
installed by Flux and does both jobs. Unlike almost everything else here it is
**not** shared from a single base — each site has its own
`kubernetes/apps/base/kube-system/cilium-<location>/` tree, so a change made for
one cluster does not silently apply to the others, and a change meant for all
three has to be made three times.

Also living in that tree, and easy to miss:

- a **descheduler CronJob**, vendored from the upstream release. It evicts pods
  on a schedule. If you are investigating unexplained restarts, check this
  before assuming a crash loop.
- a **Multus** patch, so pods can have a second interface (see the Home
  Assistant note under [Workloads](#workloads)).
- a **generic device plugin**, and a parked ClusterMesh configuration —
  `clustermesh-egress.yaml` and its values exist but are commented out of the
  kustomization, so ClusterMesh is *not* live. Tailscale is still the only path
  between sites.

### LoadBalancer addresses come from one flat pool

Each cluster has a single `CiliumLoadBalancerIPPool` named `k8s-pool` covering
the whole of `${CLUSTER_LOAD_BALANCER_CIDR}`, with a deliberately catch-all
service selector. So every `LoadBalancer` Service in the cluster draws from one
undivided range.

The consequence: **the pinned addresses documented elsewhere in this file are
hand-allocations inside that one pool, and nothing prevents a collision.** There
is no sub-pool per tier and no allocation map beyond the manifests themselves.
Before pinning a new address, grep for it.

### Those addresses reach the LAN over BGP

Cilium peers with the UniFi gateway: `CiliumBGPClusterConfig` named `unifi`,
local ASN 64514, peering `${LAN_GATEWAY_IP}` at ASN 64515, with a 9-second hold
time and graceful restart. The peer config selects which advertisements to send
by the label `advertise: bgp`, and the single shipped `CiliumBGPAdvertisement`
carries that label.

What that advertisement contains is the part worth reading twice. It advertises
Service `ClusterIP`, `ExternalIP` and `LoadBalancerIP` — with a catch-all
selector, so *all* Services, not an opt-in subset — **and the node `PodCIDR`**.

Two things follow:

- **Every ClusterIP and every pod address in every cluster is routable from that
  site's LAN.** ClusterIPs are not a security boundary here. Since the tailnet
  subnet router also advertises the pod and service CIDRs, they are reachable
  from the tailnet too. Anything that relies on "it's only a ClusterIP" for
  protection is not protected; use a `SecurityPolicy`, a NetworkPolicy, or
  tailnet policy.
- If BGP to the UDM is down, LoadBalancer Services still get addresses and still
  look healthy from inside the cluster, while being unreachable from the LAN.
  That failure presents as "DNS resolves but nothing connects", which is easy to
  misdiagnose as an ingress or certificate problem.

## Storage and data

One federated object store, two Ceph clusters.

### garage-operator

Chart 0.7.5, all three clusters. CRDs: `GarageCluster` v1beta2, `GarageNode`
v1beta1, `GarageBucket`, `GarageKey`, `GarageReferenceGrant`. ServiceMonitor
and PrometheusRules enabled, admission webhooks on.

Three committed `postRender` patch entries, serving two reasons — the first
reason needs two patches because both halves of the mismatch have to move:

1. The metrics Service is relabelled `app.kubernetes.io/component=metrics`, and
   a second patch pins the ServiceMonitor's `selector.matchLabels` to that same
   label. Either one alone changes nothing: the chart's selector otherwise
   matches both the metrics Service (8443) and the webhook Service (443),
   because they carry identical labels and both name a port `https`, so
   Prometheus 404-scrapes `/metrics` on the webhook.
2. The `GarageNodeDisconnected` rule is rewritten to
   `sum by (id) (cluster_layout_node_connected{job="garage"}) == 0` so it fires
   only when **no** peer can see a node, rather than on self-observation.

### GarageCluster `garage`

One per site; together, one logical S3 estate.

- image `dxflrs/garage` v2.3.0, zone `${LOCATION}`
- replication factor 3, `consistencyMode: consistent` (Kopia/Velero need read-after-write; see #575)
- `s3Api` rootDomain `.s3.keiretsu.top`; `webApi` rootDomain `.keiretsu.top`
- `rpcPublicAddr ${LOCATION}-garage.keiretsu.ts.net:3901`
- `remoteClusters` lists **all three** zones, each reached over the tailnet:
  admin API `http://<location>-garage.keiretsu.ts.net:3903`, gateway RPC
  `<location>-gw-{ordinal}.keiretsu.ts.net:3901`. St. Petersburg additionally
  sets `storageRpcEndpointTemplate`
  `stpetersburg-garage-spark-{ordinal}.keiretsu.ts.net:3901`.
- `rpc-secret` and `admin-token` are SOPS-encrypted

`GARAGE_STORAGE_LAYOUT_POLICY=Manual` on all three: the storage tier is
hand-declared per node so an array can move between backing stores. The gateway
tier stays operator-managed (`Auto`).

Apps never talk to the storage tier directly. They use
`COMMON_S3_ENDPOINT = garage-gateway.garage.svc.cluster.local:3900`, because
the gateway carries the full `FullReplication` `key_table` (so S3 signature auth
resolves locally) and survives local storage loss by proxying reads to a
surviving zone at `read_quorum=1`.

### Garage local pools

Declared through `GARAGE_NODE_LOCAL_POOLS`, hostPath-backed — but these are not
the only storage nodes. Ottawa and Robbinsdale each also declare a hand-written
2Ti `GarageNode` whose **data volume is the SMB share**, not a hostPath:
`ottawa-garage-smb` and `robbinsdale-garage-smb`. Both bind pre-existing PVCs
through `existingClaim` so the Garage `nodeId` and layout tags survive
untouched, and both keep metadata on Ceph RBD — which is the point: with no
local-path data volume the pod is free to reschedule to any node, so a single
machine going away is not a storage outage. Each has its own
identity-specific `rpcPublicAddr` (`<location>-garage-smb.keiretsu.ts.net:3901`)
because Garage node IDs cannot share an L4 VIP.

| Site | Pools | Notes |
|---|---|---|
| Ottawa | `local-700` 700Gi on `asuka`, `kaji`, `rei`; `local-200` 200Gi on `shiro` | RPC advertised as `ottawa-garage-pool-<node>.keiretsu.ts.net:3901`; gateway affinity excludes `asuka` (SIGILL on that node) |
| Robbinsdale | `local-700` 700Gi on `stone`, `tank`, `titan` | RPC advertised via `robbinsdale-garage-pool-<node>-v4` cluster DNS |
| St. Petersburg | `local-2ti` 2Ti on `spark-0`, `spark-1`; `local-200` 200Gi on `orin-0` (tolerates the control-plane taint) | `GARAGE_REPLICAS` 2, pods pinned to instance-type `dgx-spark` with a hostname topology spread |

All *pools* live under `/var/local-path-provisioner/garage-node-local/…` with
`priorityClassName: infra-critical`. The two SMB nodes above do not.

### Garage buckets and access

`GarageBucket` CRs include:

| Bucket | Contents |
|---|---|
| `velero` | Velero backups, prefix `${LOCATION}` |
| `zot` | OCI registry blobs, rootdirectory `/zot` |
| `mimir` | long-term metrics blocks |
| `tailscale-logs` | tailnet audit log stream |
| `forgejo` | Forgejo attachments and LFS objects |
| `bhaiya-postgres`, `firefly-postgres`, `forgejo-postgres`, `woodpecker-postgres`, `suwayomi-postgres`, `teslamate-postgres`, `immich-postgres`, `tracearr-postgres`, `omnibus-postgres`, `bookorbit-postgres` | CNPG barman-cloud WAL and base backups — one bucket per database, prefix `${LOCATION}`, so federated sites never share a Barman catalog |

One footnote on that last row, because it breaks the pattern it states:

- **`bhaiya-postgres` has a bucket but no database.** No CNPG `Cluster` of that
  name exists in this repo — bhaiya's Postgres is defined in bhaiya's own
  GitRepository. The bucket and its `GarageKey` are provisioned here so the
  credential exists before the foreign Kustomization needs it.

`GarageKey` CRs mint per-app credentials into Secrets via `secretTemplate`
(`garage-keys` / `garage-keys-ottawa`). `GarageReferenceGrant` plus Gateway API
`ReferenceGrant`s let routes in other namespaces reach Garage Services.
`garage-webui` and `garage-exporter` (Ottawa) provide UI and metrics.
`garage-webadmin/` at the repo root is the custom admin image, built by two
dedicated GitHub Actions workflows.

### Rook-Ceph — Ottawa (`CephCluster rook`)

- ceph v20.2.2 — which *is* Tentacle; v20 is the Tentacle line, and
  `allowUnsupported` stays `false`. What is bounded here is not the release but
  the mgr's log ring: v20.2.2 dumps whole Rook `PodList` responses into the
  recent-log buffer, so `cephConfig.mgr.log_max_recent: "100"` caps it until
  the upstream logging fix ([rook#17786](https://github.com/rook/rook/issues/17786))
  reaches a later Tentacle point release. Nothing is held back a major version
- mon 3; mgr 2 with modules `diskprediction_local`, `insights`,
  `pg_autoscaler`, `rook`, and `balancer upmap`
- network provider `host`, public+cluster `192.168.169.0/24`, msgr2 required
- OSDs on `asuka`, `kaji`, `rei` with `osdsPerDevice: 4`; `shiro` overrides
  to 1
- `CephBlockPool ceph-blockpool-replicated` — size 3, failureDomain host
- `CephFilesystem filesystem` — size 3, `requireSafeReplicaSize`
- StorageClass `ceph-block-replicated` (`rook-ceph.rbd.csi.ceph.com`)
- StorageClass `rook-cephfs` (`rook-ceph.cephfs.csi.ceph.com`)
- VolumeSnapshotClasses `csi-rbdplugin-snapclass`, `csi-cephfsplugin-snapclass`
- mon/OSD priorityClass `system-node-critical`, mgr `system-cluster-critical`
- `pgHealthCheckTimeout: 15` so a Talos node upgrade cannot hang forever
- the mgr dashboard is published through the `ts` Gateway

### Rook-Ceph — Robbinsdale (`CephCluster rook-ceph`)

- ceph v20.2.2; mon 3 with `allowMultiplePerNode` (only three machines exist)
- mgr 2, `rook` module only; pod network, msgr2 **not** required
- `useAllDevices: false` — devices are listed explicitly per node:
  `stone` → `nvme1n1`; `titan` → `nvme0n1`, `nvme1n1`, `sda`, `sdc`, `sdd`;
  `tank` → an `nvme*` glob **plus** `sdd` named explicitly, because the glob
  that excluded a destroyed disk was also hiding a healthy one
- `CephBlockPool ceph-blockpool-replicated-nvme` — size 3, host,
  `deviceClass: nvme`
- `CephFilesystem filesystem` — size 3
- StorageClasses `ceph-block-replicated-nvme` and `rook-cephfs`
- placement tolerates `tuppr.home-operations.com/outdated`: Rook rejects **any**
  untolerated taint when validating OSD placement, so tuppr's
  `PreferNoSchedule` taint silently stopped OSD creation on all three nodes

No `CephObjectStore`/RGW exists in either cluster — all object storage is
Garage.

### csi-driver-smb

Chart 1.20.3; Ottawa and Robbinsdale.

- StorageClass `nagato-smb` → `//192.168.169.111/media-share` (Ottawa)
- StorageClass `unas-smb` → `//192.168.50.115/k8s_shortsnap` (Robbinsdale)
- credentials in Secret `csi-smbcreds` (`kube-system`), SOPS-encrypted
- bulk media only — never databases

`STORAGECLASS_LONGTERM` is the literal string `smb` on both clusters, and
**there is no StorageClass named `smb`**. The two classes above are the
*dynamic* ones; `smb` is only the binding label shared by the hand-written
`PersistentVolume`/PVC pairs that mount the existing shares (media libraries,
Frigate and Home Assistant volumes, the Garage config PV). So a PVC that asks
for `${STORAGECLASS_LONGTERM}` binds a pre-declared static PV or stays Pending
forever — it will never dynamically provision. Point new dynamic claims at
`nagato-smb` or `unas-smb` explicitly.

### local-path-provisioner

v0.0.36, all three clusters — Robbinsdale included, via
`kubernetes/apps/robbinsdale/local-path-storage/`. StorageClass `local-path`,
`WaitForFirstConsumer`, `Delete`, fallback path
`/opt/local-path-provisioner`. It is the StorageClass for all three
St. Petersburg tiers (default, metadata, longterm), and the backing store for
the Garage hostPath pools.

### snapshot-controller

Chart 5.2.0 (piraeus-charts). `volumeSnapshotClasses` is intentionally empty
here — the classes are owned by Rook-Ceph. `csi-addons` adds RBD network
fencing (Ottawa, Robbinsdale). `secrets-store-csi-driver` 1.5.4 backs the
Tailscale CSI provider.

### Velero

Chart 12.1.0, velero v1.18.2, aws plugin v1.14.2.

`BackupStorageLocation garage` — provider `aws`, bucket `velero`, prefix
`${LOCATION}`, region `garage`, `s3Url http://${COMMON_S3_ENDPOINT}`,
`s3ForcePathStyle`. **The prefix MUST be a sibling of `bucket`**; nested under
`config` it is silently ignored and every cluster shares one kopia repo.

`volumeSnapshotLocation` is empty — PV data is captured by kopia fs-backup
through the node agent, not by CSI snapshots.

`node-agent-config` sets `loadConcurrency: 2` and `prepareQueueLength: 8`,
because the default of 1 lets one wedged `PodVolumeBackup` fail the whole node.

Credentials come from a `GarageKey`-populated Secret, not the chart's file.
`velero-ui` (Ottawa) exposes it; a `bhaiya-velero` Role lets the bhaiya
ServiceAccount manage its own backups.

Schedules, all TTL 168h:

| Cluster | Schedules |
|---|---|
| Ottawa | `bhaiya` 08:00 · `cliproxy` 09:00 · `hermes` 07:00 · `home`+`tinyauth` 09:00 · `media-config` 06:00 (config only) |
| Robbinsdale | `home` 09:00 · `media-config` 06:00 (config only) |
| St. Petersburg | `home-assistant` 09:00 |

`media-config` deliberately sets `defaultVolumesToFsBackup: false` — the bulk
data lives on Ceph/SMB and relies on storage-layer durability.

### CloudNativePG

Chart 0.29.0, all three clusters. Nine Postgres Clusters, two instances each
except `lobby-postgres` (1):

| Cluster | Storage | Notes |
|---|---|---|
| `forgejo-postgres` | `ceph-block-replicated` 10Gi | |
| `woodpecker-postgres` | `ceph-block-replicated` 10Gi | |
| `lobby-postgres` | `ceph-block-replicated` 5Gi | database conference; 1 instance |
| `teslamate-postgres` | default class 8Gi | `postgresql:18` |
| `suwayomi-postgres` | default class 10Gi | |
| `immich-postgres` | 16Gi Ottawa / 40Gi Robbinsdale | vectorchord image; the larger volume is the Robbinsdale one |
| `tracearr-postgres` | 40Gi Ottawa / 20Gi Robbinsdale | |
| `omnibus-postgres` | 10Gi | |
| `bookorbit-postgres` | 10Gi | vectorchord + pgvector/trgm/unaccent |

barman-cloud `ObjectStore` CRs push WAL and base backups to Garage at
`s3://<db>-postgres/${LOCATION}/` with `ScheduledBackup`s overnight. A
PodMonitor and a Grafana dashboard ship with the operator.

### Caches

The Dragonfly operator is a vendored upstream release manifest v1.6.1 pulled by
Kustomize — the only storage operator not delivered as a HelmRelease.

Dragonfly CRs (2 replicas each): `dragonfly-tracearr`, `dragonfly-omnibus`,
`dragonfly-immich`, `dragonfly-zot`. Note that `immich` names the file
`redis.yaml` but the kind is `Dragonfly` — there is no real Redis anywhere in
the repo.

Valkey has one genuine instance: searxng's local chart, storage disabled.

`zot-cache-ottawa` exposes `dragonfly-zot` to the other clusters, and zot's
`remoteCache` points at `zot-cache:6379`.

### Zot OCI registry

Chart 0.1.122, zot v2.1.20, Ottawa.

- 2 replicas, persistence **false** — all state in Garage S3 plus Dragonfly;
  the Service uses three-hour ClientIP affinity so each resumable OCI upload
  stays on one Zot process through its POST/PATCH/PUT sequence
- `storageDriver: s3`, bucket `zot`, region `garage`, `forcepathstyle`
- retention keeps the 10 most recently pushed and pulled tags, 720h windows
- gc on (delay 1h, interval 6h); dedupe off
- htpasswd auth from a SOPS-encrypted secret; anonymous read/create/update
- sync extension mirrors `ghcr.io` on demand, 6h poll
- search, UI and metrics extensions enabled
- reachable cross-cluster as `<location>-zot.keiretsu.ts.net:5000`

### Strimzi / Kafka — parked

Robbinsdale only, and **the pointer is commented out**.

- chart `strimzi-kafka-operator` 1.1.0, `watchAnyNamespace`
- `Kafka robbinsdale`, KRaft mode (no ZooKeeper), Kafka 4.3.0
- listener `raj` `:9092` cluster-ip, SCRAM-SHA-512 over TLS
- KafkaNodePools `broker` (2) and `controller` (1),
  `ceph-block-replicated` 10G
- cert-manager Certificate `kafka-raj-tls` for `*.kafka.k8s.rajsingh.info`
- 4 TLSRoutes (3 brokers + bootstrap) that point at Gateway `private` in
  namespace `envoy-gateway-system`, `sectionName: kafka-listener` — a
  namespace with no Gateway in it, and a section the real `private` Gateway
  in `home` does not have. Fix both before un-parking this.

The namespace directory and kustomization still list `strimzi.yaml`, but every
line of that pointer is commented out, so it renders to nothing today.

---

## Observability

Collected everywhere, stored and queried in Ottawa.

### kube-prometheus-stack

One per cluster, delivered from an `OCIRepository`, not a HelmRepository. The
Flux Kustomization is named **`monitoring`** (with a sibling named `config`);
`monitoring-common` is the *base directory* it points at, not something you can
`flux reconcile`.

- Prometheus runs in **`agentMode: true`** with `defaultRules.create: false`:
  each cluster's Prometheus is a forwarder, not a store or an evaluator. Rules
  and long retention live centrally, which is why a local `promtool`-style
  query against it looks empty
- Prometheus `externalLabels cluster=${CLUSTER_NAME}` — this is what keeps the
  three clusters' series apart once they land in one Mimir
- `remoteWrite` →
  `http://mimir-gateway.mimir.svc.cluster.local:8080/api/v1/push`
- alertmanager enabled, with a SOPS-encrypted config secret and an
  `AlertmanagerConfig` object
- node-exporter and kube-state-metrics on; the bundled Grafana is **disabled**
  because Grafana is a single Ottawa deployment
- the chart's `honorTimestamps=true` on the cadvisor endpoint is overridden in
  **HelmRelease `values`** — not a `postRenderers` patch — and both
  `honorTimestamps` and `trackTimestampsStaleness` have to be set `false`
  together or neither takes effect. The reason: cadvisor on constrained nodes
  (the Jetson Orin) reports lagging embedded timestamps, and honouring them
  drops roughly 10k samples per scrape as out-of-order. Scrape time is slightly
  less precise for rates and loses nothing

### Mimir — long-term metric store, Ottawa only

Chart `mimir-distributed` 6.1.0, `mimir-ottawa` overlay. Blocks and ruler live
on Garage S3, bucket `mimir` (ruler under prefix `ruler/`).
`compactor_blocks_retention_period` 7d. The nginx gateway runs 2 replicas so
remote-write survives a rollout. Reachable on the tailnet as
`mimir.keiretsu.ts.net:8080`, and `mimir-qf.keiretsu.ts.net:9095` for
query-frontend gRPC.

Robbinsdale and St. Petersburg deploy only `mimir-egress` — the ExternalName
Services that make the local `mimir-gateway` name resolve to Ottawa.

### VictoriaLogs — log store, Ottawa only

Chart `victoria-logs-single` 0.13.9, 50Gi, retention 7d. Published as
`victoria-logs.keiretsu.ts.net` plus a ts-gateway route.

**The trick worth copying:** `VICTORIA_LOGS_HOST` is the *same string* in all
three clusters
(`victoria-logs-victoria-logs-single-server.monitoring`). In Ottawa that name
is the real Service. In the other two clusters the location tree ships only an
ExternalName Service of exactly that name pointing at the tailnet FQDN, so
Fluent Bit needs no per-cluster configuration at all.

### Fluent Bit

One per cluster.

- **inputs** — tail of container logs (`kube.*`), plus a TCP listener on 5170
  that receives Talos logs. All three clusters ship *service* logs there via a
  `machine.logging.destinations` patch
  (`bootstrap/talos/patches/global/machine-logging.yaml`, `json_lines`, tagged
  `cluster=<location>`). The **kernel** stream is the part that is not
  universal: Ottawa and St. Petersburg add
  `talos.logging.kernel=tcp://<site>.69.51:5170/` as a kernel arg in
  `talconfig.yaml`, and **Robbinsdale does not** — so Robbinsdale contributes
  service logs but no kernel logs, and an empty kernel view for those nodes is
  expected rather than a broken collector
- **filters** — Kubernetes metadata is merged into the record and its
  `kubernetes.*` fields are retained; unparsed container lines fall back from
  `log` to `msg`, while temporary Kubernetes label aliases are removed before
  shipping. Talos `syslogd` records likewise copy `content` to `msg`
- **outputs** — two loki-protocol outputs to `${VICTORIA_LOGS_HOST}:9428`,
  gzip, with `VL-Msg-Field msg` for both `kube.*` and `talos.*`; Kubernetes
  streams are labelled `namespace`, `pod`, `container`, and `stream`, while
  the Talos output promotes its existing `tag` field (such as `kata` or
  `virtiofsd`) as a stream label

**Historical Kubernetes log query:** records ingested before the Kubernetes
message/label mapping was corrected may have their body in the structured
`msg` field but no `_msg` value or stream labels. Search those records by their
retained fields, for example
`kubernetes.namespace_name:bhaiya and msg:"ensure workspace routes"`.
Fixing the pipeline does not rewrite VictoriaLogs history, so old records do
not acquire `_msg`, `namespace`, `pod`, `container`, or `stream` labels.

### Grafana — single pane, Ottawa only

grafana-operator based: app + instance + dashboards + datasources. Datasources:
Prometheus (`mimir-local`), Mimir, Mimir-Ottawa, Mimir-Robbinsdale,
Mimir-StPetersburg (all through the local `mimir-gateway`; the `cluster` label
separates them), VictoriaLogs, Alertmanager. `grafana-mcp` exposes Grafana to
agents over MCP.

Robbinsdale and St. Petersburg each deploy a Kustomization named
`grafana-redirect` instead of a second Grafana, so `grafana.<their domain>`
lands on the Ottawa instance. (St. Petersburg's points at the base directory
`grafana-redirect-stpetersburg`; the Kustomization identity is still
`grafana-redirect`.)

### monz — a second, independent stack (Ottawa)

Its own VictoriaLogs and VictoriaMetrics HelmReleases, Grafana instance,
datasources and dashboard, published at `monz.keiretsu.top` with its own `ts`
ingress routes for the VL and VM components. Kept deliberately separate from
the primary `monitoring` namespace.

### Gatus — external synthetic checks

The Flux Kustomization is named **`gatus`** in all three clusters — only the
base directory varies (`gatus-ottawa`, `gatus-robbinsdale`, and plain `gatus`
for St. Petersburg), so `flux reconcile kustomization gatus` is the command
everywhere. Published at `status.<cluster domain>` and `status.keiretsu.top`
via GSLB. It probes both
in-cluster endpoints and their tailnet equivalents — for example Ottawa checks
`mimir-gateway.mimir:80/ready` *and* `mimir.keiretsu.ts.net:8080/ready`, so a
mesh break is distinguishable from a service failure.

### Kromgo — the README badges

Serves `cluster_*` badge endpoints at `kromgo.<cluster domain>`. It runs an
nginx `mimir-proxy` sidecar and points `KROMGO_PROMETHEUS_URL` at
`127.0.0.1:9090/prometheus`, so the badges read from Mimir. Exposed on the
public Gateway — this is what renders the shields at the top of the README.

### Exporters and probes

- `blackbox-exporter` plus one per-cluster variant each. Probes:
  `app-k8s-api-readyz` (http_401 against the API `readyz`), `app-internet`
  (http_2xx to public DNS), `app-internet-icmp` (ping). The rules live in
  `PrometheusRule` **`blackbox-exporter-rules`** — `blackbox-exporter.rules` is
  the group name inside it, not the object, so that is the string to `kubectl
  get prometheusrule`. Four alerts, not two: `ProbeFailed` (5m) and
  `ProbeSlowResponse` (>5s), plus `SSLCertExpiringSoon` and `SSLCertExpired`,
  which is where certificate expiry is actually caught — cert-manager renewal
  failures surface here rather than in the cert-manager section above.
- `smartctl-exporter` — disk health, Ottawa and Robbinsdale (they have the
  disks)
- `unpoller` — UniFi controller metrics, all three clusters
- `opencost` — cost attribution, Ottawa
- `k8gb-prometheus` / `k8gb-monitoring` / `k8gb-dashboard` — GSLB visibility,
  Ottawa
- `hubble-ui` — Cilium flow visibility, all three clusters
- `headlamp` — cluster UI, Ottawa. The Kustomization is `headlamp-install`
  (base directory `kube-system/headlamp/install`), not `headlamp`
- `flux-monitoring` — Flux controller ServiceMonitors and dashboards
- `garage-exporter` — Garage metrics, Ottawa

---

## Workloads

### media-apps — Ottawa (Flux Kustomization `media-apps`, ns `media`)

`plex`, `overseerr`, `tautulli`, `wizarr`, `maintainerr`, `kometa`;
`sonarr-1080p`, `sonarr-4k`, `sonarr-anime`; `radarr-1080p`, `radarr-4k`,
`radarr-4kremux`, `radarr-anime`; `bazarr-1080p`, `bazarr-4k`,
`bazarr-4kremux`, `bazarr-anime`; `prowlarr`, `autobrr`, `configarr`,
`flaresolverr`, `feedcord`; `sabnzbd`, `qb`, `qb-pvt` (usenet plus two torrent
clients); `lidarr`, `audiobookshelf`, `komga`, `suwayomi`, `bookorbit`,
`shelfmark`; `omnibus`, `tracearr`.

Ottawa-only titles: `audiobookshelf`, `komga`, `suwayomi`, `bookorbit`,
`shelfmark`, `omnibus`.

Bulk libraries live on the `nagato-smb` share; databases on Ceph RBD.

qBittorrent is private+ts only. Its public CDN route was removed: the pod-CIDR
auth whitelist made Envoy traffic bypass qBittorrent login.

### media-apps — Robbinsdale (ns `media`)

The same stack minus the book/manga/audiobook titles: `plex`, `overseerr`,
`tautulli`, `wizarr`, `maintainerr`, `kometa`; `sonarr-1080p`, `sonarr-4k`,
`sonarr-anime`; `radarr-1080p`, `radarr-4k`, `radarr-4kremux`,
`radarr-anime`; `bazarr-1080p`, `bazarr-4k`, `bazarr-4kremux`,
`bazarr-anime`; `prowlarr`, `autobrr`, `configarr`, `flaresolverr`,
`feedcord`; `sabnzbd`, `qb`, `qb-pvt`, `lidarr`, `tracearr`.

Bulk libraries on the `unas-smb` share; databases on
`ceph-block-replicated-nvme`.

### `home` namespace — the shared portal (all three clusters)

- `homepage` — the dashboard
- `homer` — second dashboard, generated by `homer-operator`
- `dnsrecords` — DNSEndpoint objects for site-local names
- `local-gateway` — the `public` and `private` Gateways, GatewayClasses,
  EnvoyProxies
- `tailscale-gateway` — the `ts` Gateway, its GatewayClass and EnvoyProxy

`home-apps-ottawa` adds `frigate`, `home-assistant`, `unifi-webhook`.
`home-apps` (Robbinsdale) adds `frigate`, `home-assistant`, `mqtt`.
St. Petersburg runs `home-assistant` as its own namespace instead.

### `ai` namespace — inference on the DGX Sparks (St. Petersburg)

**`LeaderWorkerSet glm53`** — replicas 1, size 2. The leader is pinned to
`spark-0` and the worker to `spark-1`. It serves the
`Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw` checkpoint under vLLM with TP=2,
DFlash2 k=7 speculative decoding, packed FP8 MLA KV, and a 1M-token context,
so **one model spans both machines**. The ranks talk over the
`192.168.74.0/30` RDMA rail (`VLLM_HOST_IP` and `--master-addr` are the RDMA
addresses, not the LAN ones). The served model is
`GLM-5.3-Flash-EXL3`; the `vllm` provider also offers the
`GLM-5.3-Flash` alias. Head and worker have separate 200Gi model PVCs, and a
drop-caches loop keeps unified memory available. Each vLLM rank requests
`94Gi` and is limited to `96Gi`; the target image supplies the SM121 sparse-MLA
and EXL3 runtime. The image is consumed at its pinned MiaAI-Lab arm64 digest;
there is no in-repo serving-image build. No unrelated GPU workload should be
scheduled on either Spark without a fresh load qualification.

The `glm53` ServiceMonitor scrapes the vLLM endpoint at
`glm53.ai.svc.cluster.local:8000/metrics` every 15s. The blackbox `Probe
app-vllm` hits `/health` **and** `/v1/models`, because a served-model list proves
the weights actually loaded, which `/health` alone does not.
`HUGGING_FACE_HUB_TOKEN` comes from a SOPS-encrypted secret.

Consumers reach it as `stpetersburg-vllm.keiretsu.ts.net`; `hermes` and
`cliproxy` both declare that egress Service.

### GPU / sandbox runtime stack

**`gpu-operator`** (chart 26.3.3, St. Petersburg):

- driver and toolkit **disabled** — Talos extensions provide both
- `runtimeClass nvidia`, device-plugin 1 replica per GPU, with **no
  time-slicing**: a single vLLM consumer gains nothing from fake slots
- `mig.strategy: none` — GB10 has no MIG firmware path
- gfd on; dcgm-exporter on with a ServiceMonitor
- the validator runs with `WITH_WORKLOAD=false` — there is no spare GPU to
  test on
- only the chart's **bundled** NFD subchart is disabled (`nfd.enabled: false`),
  because standalone `nfd-install` / `nfd-rules` already run in namespace
  `node-feature-discovery` — running two NFD instances would fight. That is a
  deduplication, *not* the reason the GPU labels are hand-set: the real reason
  is that NFD does not synthesize the labels gpu-operator looks for on Talos
  (`feature.node.kubernetes.io/pci-10de.present`, the
  `system-os_release.*` set, `cpu-model.vendor_id`), so without them the
  ClusterPolicy reconciler cannot find the GPU nodes and refuses to deploy the
  device-plugin DaemonSet — see the node patches, which say so in a comment

Companions:

- `rdma-shared-dp` — exposes the spark-to-spark RDMA devices to pods
- `lws-system` — the LeaderWorkerSet controller that `glm53` depends on
- `k8s-gpu-dra-driver` — DRA-based GPU allocation, Ottawa
- `kata-containers` — RuntimeClasses `kata-clh`, `kata-workspace`,
  `kata-tailscale` (Ottawa). `kata-tailscale` is the only one with the Talos
  PodSecurity exemption, which is what lets an embedded Tailscale workspace
  open a TUN device. A `kata-canary` Deployment health-checks the runtime.
- `gvisor` — the other sandbox RuntimeClass, all three clusters
- `agent-sandbox` — the sandbox controller, all three clusters

### Ottawa-only services

| App | Notes |
|---|---|
| `bhaiya` | workspace/sandbox control plane. Reconciled from its **own** GitRepository (Forgejo), not from this repo. This repo keeps the GitRepository, Forgejo credentials, and the Flux pointer (`dependsOn` garage, garage-keys, cnpg-system, agent-sandbox, cert-manager). The Receiver, Firefly MCP secret, and home Gateway editor Role live in `corp/bhaiya`. Platform TLS (`*.bhaiya`), k8gb apex route, GarageKey, Velero schedule, and Mimir rules stay here. |
| `hermes` | agent runtime (`hermes-agent`); egresses to `stpetersburg-vllm` and `aperture` on the tailnet |
| `firecrawl` | web-scraping stack, reconciled straight from the upstream GitHub repo's `examples/kubernetes/cluster-install` path |
| `cliproxy` | LLM API proxy (`cli-proxy-api`); egress to `stpetersburg-vllm` |
| `forgejo` | self-hosted Git — and the source of truth for bhaiya. SSH on `:22` through the `private` and `ts` Gateways. |
| `woodpecker` | CI paired with Forgejo, with a persistent Nix cache workspace |
| `searxng` | metasearch, backed by the one real Valkey in the repo |
| `teslamate` | vehicle telemetry plus a secret-sync helper and a Grafana datasource |
| `immich` | photos (also on Robbinsdale); vectorchord Postgres + Dragonfly |
| `zot` | OCI registry, plus `zot-cache-ottawa` for the shared Dragonfly |
| `lan` | ExternalName entries for LAN appliances |
| `tempvm` | on-demand VM gateway in its own `tempvm` namespace; exposed as a tailnet **device** via `loadBalancerClass: tailscale`, not as a Tailscale Service |
| `headlamp` | Kubernetes UI |
| `opencost` | cost attribution |
| `grafana-mcp` | MCP bridge in front of Grafana |
| `monz` | the parallel VictoriaMetrics/VictoriaLogs/Grafana stack |

### Elsewhere

- **Robbinsdale** — `speedtest` (openspeedtest), `cloudflared` tunnel,
  `cert-manager-issuers` (`luke-issuer` only; the rest come from the shared
  set), `grafana-redirect`, `tinyauth-egress`, `strimzi` (disabled).
- **St. Petersburg** — `home-assistant`, `grafana-redirect`,
  `cloudflare-cluster-app`, `flux-system-stpetersburg`, `tinyauth-egress`.
- **All three** — `actions-runner-controller` plus runner scale sets that dial
  out to GitHub, `spegel` peer-to-peer image mirroring, `default-debug` and
  `default-kubernetes` helpers, `kro` and its
  ResourceGraphDefinitions, `vpa`, `memory-request-floor`, `priority-classes`,
  `irqbalance` (Ottawa + St. Petersburg), `node-feature-discovery`, `tuppr`,
  `external-secrets`, `csi-secrets-store`.

**`goldpinger` is not deployed anywhere.** Manifests for it sit in
`kubernetes/apps/base/default/default-common/goldpinger/`, but that directory
has no `kustomization.yaml` and nothing lists it, so it renders to nothing —
there is no pod-to-pod mesh probe in any cluster today. Do not reason about
mesh health from it; use Hubble and the Gatus tailnet checks instead.

### Platform primitives worth naming

**`priority-classes`** — none is `globalDefault`:

| Class | Value | For |
|---|---|---|
| `infra-critical` | 1000000000 | Tailscale proxies, CNI, cert-manager, Flux, Garage pools |
| `infra-high` | 800000000 | Garage, monitoring, gateways, database operators |
| `infra-default` | 500000000 | everything else that must not preempt infrastructure |

- **`memory-request-floor`** — raises implausibly small memory requests.
- **`vpa`** — right-sizes requests over time.
- **`kro`** — ResourceGraphDefinitions turn repeated shapes into one custom
  resource, including `ServiceEgress`, which generates the tailnet egress
  pattern.
- **`spegel`** — nodes serve image layers to each other; this is why containerd
  keeps `discard_unpacked_layers=false`.
- **`tuppr`** — drives Talos and Kubernetes upgrades, gated on Node Ready plus
  (where present) `CephCluster`, `GarageCluster` and CNPG health.
- **`external-secrets`** — ClusterSecretStore-backed secret projection.
- **`open-cluster-management`** — Ottawa is the hub (`ocm` + `ocm-grpc-lb`);
  every cluster runs `ocm-agent` and registers through
  `ocm-grpc-hub.keiretsu.ts.net:443`.

---

### Sandbox runtimes, and the one that is different

Three Kata RuntimeClasses exist in Ottawa — `kata-clh`, `kata-workspace` and
`kata-tailscale` — plus `gvisor` in all three clusters and the `agent-sandbox`
controller.

- **`kata-workspace`** is the runtime for all user-executed workspaces and
  shared-browser sessions. Do not move these back to gVisor.
- **`kata-tailscale`** is the only class carrying the Talos PodSecurity
  exemption, which is what lets a workspace open a TUN device and run Tailscale
  *inside* its own container. Do not grant that exemption to ordinary sandboxes.
- A `kata-canary` Deployment health-checks the runtime. Note it pins
  `runtimeClassName: kata-clh`, so it proves that class works — not the
  Tailscale one.

Embedded-Tailscale workspaces run in kernel TUN mode inside a single Kata
container. Two things people reach for and should not:

- **Do not reintroduce an external Tailscale gateway sidecar**, and do not carve
  site CIDRs in the tailnet policy, as a workaround for asymmetric pod replies.
  The workspace entrypoint already handles this: it marks connections arriving
  through the CNI and routes their replies back through the main table, while
  leaving new accepted-route traffic on `tailscale0`.
- **HuJSON `grants` and `via` rules do not control route injection.** They
  authorise traffic and make a router eligible. If a route is not present, that
  is not a grants problem, and adding grants will not fix it.

### One listener trusts a header as identity

The authorization model above rests on Tinyauth injecting `Remote-Email` and
each route's `SecurityPolicy` allow-listing values of it. That only holds while
nothing else can set that header.

Bhaiya's UI listener trusts `Remote-Email` as identity, so its destination-side
Cilium policy must keep that listener unreachable from workspace traffic and
from subnet-router traffic. This is a destination-side control on purpose:
source-side workspace policy cannot see the final destination when it is carried
inside an accepted Tailscale route, so it cannot make this decision. Read that
together with the BGP note above — ClusterIPs are LAN- and tailnet-routable —
before changing anything about who can reach that listener.


## What breaks when a site goes down

The three clusters are not interchangeable, so "a site is down" has three
different answers. Read this before assuming a failure is local.

### Access itself rides the tailnet

Every documented path to every cluster's API goes through the Tailscale
operator's `${LOCATION}-k8s` ProxyGroup: that is what serves
`<location>-k8s-operator.keiretsu.ts.net`, and it is the server URL in the
committed kubeconfig. `tools/kc.sh` uses that kubeconfig.

**If the operator or its ProxyGroup is down in a cluster, you lose kubectl to
that cluster — and the outage that took it down is probably the thing you
wanted to inspect.** Recovering means going around Kubernetes: `talosctl`
against the machine addresses, or the `KUBERNETES_API_VIP` from inside the LAN.
Both are listed per cluster under [Per-cluster facts](#per-cluster-facts). Treat
knowing which of those you can reach from where you are as part of on-call
readiness, not something to work out during an incident.

### If Ottawa is down

Ottawa holds the singletons, so its loss degrades the other two sites rather
than merely removing itself:

| Also lost | Why | Visible as |
|---|---|---|
| Authentication on Robbinsdale and St. Petersburg | Neither runs a local Tinyauth; both reach Ottawa's through `tinyauth-egress` | protected routes stop authenticating everywhere |
| Long-term metrics | `mimir-egress` at the other two sites points at Ottawa's Mimir | remote-write fails; local Prometheus keeps only its own window |
| Log ingest | the shared `VICTORIA_LOGS_HOST` resolves to Ottawa outside Ottawa | Fluent Bit backs up and drops |
| Grafana | single deployment; the other sites only redirect to it | every dashboard, including the ones you would use to diagnose this |
| The Zot registry | Ottawa-only, with the shared Dragonfly cache | image pulls fall back to upstream registries |
| The Open Cluster Management hub | Ottawa is the hub; the others are agents | fleet view only; workloads keep running |

Two things this table does **not** say, and both matter:

- **Workloads at the other two sites keep running.** They lose telemetry,
  authentication on protected routes, and their view of themselves — not their
  pods.
- **Ottawa is not a pure hub.** It has live egress dependencies *on* the other
  two: `stpetersburg-vllm` (consumed by `hermes` and `cliproxy`),
  Robbinsdale's identity provider and SMB share, and full-mesh Garage RPC to
  every remote storage node. The relationship is asymmetric, not one-directional,
  so "Ottawa is the hub" is a statement about singletons, not about traffic.

### If Robbinsdale or St. Petersburg is down

Ottawa keeps its own telemetry, auth and registry. What it loses is whatever it
consumes from that site — inference from St. Petersburg, the identity provider
and SMB share from Robbinsdale — plus one Garage zone (see below). Ottawa is
also each of their k8gb failover targets, so GSLB names should converge on
Ottawa's edge on their own.

### Garage: one zone is survivable, two are not

Replication factor 3 across exactly three zones. The fleet default is
`consistencyMode: consistent` (read-after-write) because Velero/Kopia
maintenance depends on it: Kopia writes `_maintenance` then immediately HEADs
that same object and treats Garage `Last-Modified` as the repository clock
(#575). Under `degraded`, that HEAD can return a ~1h-stale replica and Kopia
refuses prune as "clock skew" even when every node is NTP-synced.

- **One zone down under consistent:** writes still need quorum; reads that
  cannot gather quorum fail closed rather than serving a single stale replica.
  Prefer temporary `GARAGE_CONSISTENCY_MODE=degraded` only for an explicit drain
  or availability window, then restore `consistent`.
- **Two zones down:** you are below write quorum. Treat it as an outage of the
  object store, not a degradation.

OCI blobs and Barman WAL can tolerate eventual-consistent reads. Kopia's
maintenance schedule blob cannot. That argument is written beside the setting
in `garagecluster.yaml` under `kubernetes/apps/base/garage/garage/`.

Note also that the storage tier is `Manual` at all three sites while the gateway
tier is operator-managed, and that retirement of a node with positive capacity
is deliberately blocked (`drain.unverifiedPeersPolicy: Block`) until every site
agrees on consistency mode. Neither is a failure mode, but both change what you
are allowed to do *during* one.

### Ceph and per-site block storage

Ceph exists only at Ottawa and Robbinsdale, one `CephCluster` each, with
`failureDomain: host`. Ottawa has three control planes plus a worker and
tolerates losing one machine; Robbinsdale has exactly three machines, all
control plane, with `allowMultiplePerNode` mons — so losing one machine there is
proportionally a much larger event. St. Petersburg has no Ceph at all: every
tier is `local-path`, which means node-local and not replicated. A St. Petersburg
worker loss is data loss for anything that was only on that node.

### The single control plane at St. Petersburg

St. Petersburg has one control plane, `orin-0`, and it is tainted so that
workloads land on the Spark machines. There is no control-plane redundancy: any
patch, reboot or failure of that machine is a full control-plane outage for the
site. The GPU workloads keep running — kubelet does not need the API server to
keep containers alive — but nothing can be scheduled, changed or reported until
it returns. Plan changes there as maintenance windows, and see
[Upgrades and operational ordering](#upgrades-and-operational-ordering).

## Upgrades and operational ordering

Most of this repository is declarative and order-independent: commit it and
Flux converges. These are the exceptions, where doing the right things in the
wrong order breaks a cluster.

### Talos control-plane patches are rolling operations

A machine-config patch can restart static control-plane pods **even when
`talosctl` reports `Applied configuration without a reboot`**. That message is
about the node not rebooting, not about the control plane staying up.

Never patch multiple control-plane nodes back to back. Apply to exactly one
node, then confirm all three of the following before touching the next:

- that node's etcd member is healthy,
- its kube-apiserver is serving `/readyz`,
- every Kubernetes node reports `Ready`.

Treat whichever node currently holds the control-plane VIP as the last one in
the sequence, and repeat the same three checks after it comes back. Ottawa and
Robbinsdale have three control planes and tolerate losing one; St. Petersburg
has exactly one, so any patch there is a full control-plane outage and should
be planned as such.

### Rook-Ceph upgrades are per cluster, and Rook goes before Ceph

Renovate groups storage the same way it groups Talos: `rook-<location>` and
`ceph-<location>`, one PR each, configured in `.renovate/groups.json`.

Merge the cluster's **Rook operator** PR first and let it settle. The ordering
is not arbitrary — a new operator knows how to drive an older Ceph release,
while an older operator does not know how to drive a newer one. Only then merge
that cluster's Ceph image PR. Never leave two clusters' storage rollouts in
flight at the same time.

`CephCluster.spec.cephVersion.image` and the `rook-ceph-tools` image must move
together. `tools/check-versions.sh` fails the build when they drift, with
`# version-sync: ignore` as the deliberate escape hatch.

### tuppr drives node upgrades, gated on health

Talos and Kubernetes version upgrades are carried out by tuppr rather than by
hand, and it holds off on a node until that node is `Ready` and — where the
resource exists — the `CephCluster`, `GarageCluster` and CNPG clusters report
healthy. This is why `pgHealthCheckTimeout` is capped: an unbounded Ceph health
check can otherwise hang a node upgrade indefinitely. It is also why Rook's
placement tolerates `tuppr.home-operations.com/outdated` — see the Robbinsdale
note under [Storage and data](#storage-and-data).

### Run SOPS from the directory that owns the creation rules

`.sops.yaml` files sit beside the trees they govern, and SOPS resolves rules
relative to the working directory. Editing an encrypted file from the wrong
directory can silently apply the wrong creation rules.

```bash
cd clusters/common      && sops flux/vars/common-secrets.sops.yaml
cd clusters/talos-ottawa && sops flux/vars/cluster-secrets.sops.yaml
```

Never commit plaintext secrets, kubeconfigs, `talsecret.yaml`, private keys, or
decrypted `*.dec` files.

### Everything durable goes through Git

Never `helm install` or `kubectl apply` a manifest directly, and do not use
`kubectl create`, `replace` or `edit` for anything meant to last: Flux will
revert it, or worse, will not and the cluster will quietly diverge from the
repository. `kubectl apply` also cannot resolve the Flux `${VARIABLE}`
substitutions that most manifests here depend on, so a hand-applied copy is not
even the same object. A narrowly scoped live `kubectl patch` is reserved for
incident mitigation that someone has explicitly asked for; record the durable
change in Git immediately afterwards and remove any temporary object.

## Per-cluster facts

### Ottawa

`talos-ottawa` · Ontario, Canada · `SITE_ID` 2 · `killinit.cc` · failover
target robbinsdale · `America/New_York`. 121 Flux Kustomizations across 59
namespaces.

- `clusterName k8s.killinit.internal`, endpoint `:6443`
- Talos v1.13.7 · Kubernetes v1.36.3 (tuppr targets match)
- CNI `none` in Talos — Cilium is installed by Flux; kube-proxy disabled
- scheduling allowed on control planes
- `LAN_CIDR 192.168.169.0/24` · `KUBERNETES_API_VIP 192.168.169.25`
- `CLUSTER_POD_CIDR 10.3.0.0/16` · `CLUSTER_SERVICE_CIDR 10.2.0.0/16`
- `CLUSTER_LOAD_BALANCER_CIDR 10.169.0.0/16`
- 4via6 `fd7a:115c:a1e0:b1a:0:2::/96`
- `STORAGECLASS_DEFAULT` and `_METADATA` = `ceph-block-replicated`;
  `_LONGTERM` = smb
- `COMMON_S3_ENDPOINT garage-gateway.garage.svc.cluster.local:3900`
- logs shipped to `10.169.69.51:5170` — service logs via
  `machine.logging` (json_lines, tag `cluster=ottawa`), kernel logs via the
  `talos.logging.kernel` kernel arg

Talos machines (amd64):

| Node | Role | Address | Hardware |
|---|---|---|---|
| `rei` | control plane | 192.168.169.118, holds VIP | `bond0` 802.3ad LACP, layer3+4 hash; Intel X710 SFP+ dual port |
| `asuka` | control plane | 192.168.169.117, holds VIP | `bond0` 802.3ad LACP, Intel X710 SFP+; excluded from Garage gateway scheduling (SIGILL) |
| `kaji` | control plane | 192.168.169.119, holds VIP | `bond0` 802.3ad LACP, Intel X710 SFP+ |
| `shiro` | worker | 192.168.169.116 | `bond0` 802.3ad LACP, Intel X710 SFP+; label `workload-class=specialized`; Intel platform: i915 + intel-ucode, `hwp_dynamic_boost` |

Talos machine config (talhelper):

- **control-plane extensions** — `amd-ucode`, `amdgpu`, `gvisor`,
  `kata-containers`, `nut-client`, `binfmt-misc`, `util-linux-tools`
- **shiro extensions** — `gvisor`, `i915`, `intel-ucode`, `kata-containers`,
  `nut-client`, `binfmt-misc`, `util-linux-tools`
- **kernel args** — `iommu=pt`, `mitigations=off`, `security=none`,
  performance governor, `amd_pstate=active` (control planes) /
  `intel_idle.max_cstate=0` (shiro)
- **sysctls** — BBR + fq qdisc, 64 MiB socket buffers, TCP fastopen, raised
  inotify limits, `vm.nr_hugepages=1024`,
  `user.max_user_namespaces=11255` (gVisor)
- **kubelet** — max-pods 400, rotate-server-certificates,
  `imageMaximumGCAge` 24h (with GC thresholds 60/70% and `imageMinimumGCAge`
  5m), graceful shutdown tiers
- **containerd** — CDI spec dirs, unprivileged ports/icmp,
  `discard_unpacked_layers=false` so Spegel can serve layers
- **PodSecurity** — admission exemption for RuntimeClass `kata-tailscale`
- **etcd** — metrics on `0.0.0.0:2381` for Prometheus
- **kubelet mount** — `/var/local-path-provisioner` bind, `rshared`

The full inventory of Flux Kustomizations per namespace for this cluster is in
[`inventory.md`](inventory.md), generated from the pointer files themselves.

### Robbinsdale

`talos-robbinsdale` · Minnesota, USA · `SITE_ID` 1 · `lukehouge.com` ·
failover target ottawa · `America/Chicago`. 86 Flux Kustomizations across 43
namespaces.

- `clusterName k8s.robbinsdale.local`, endpoint `:6443`
- Talos v1.13.8 · Kubernetes v1.36.3, matching `talconfig` and both siblings.
  It was pinned at v1.36.1 while the `TalosUpgrade` was failing; that upgrade
  now reports Completed with all three nodes on v1.13.8, so the hold and its
  `version-sync: ignore` marker were lifted and Renovate tracking restored.
- three machines, **all control plane** — no dedicated workers
- `LAN_CIDR 192.168.50.0/24` · `KUBERNETES_API_VIP 192.168.50.25`
- `CLUSTER_POD_CIDR 10.1.0.0/16` · `CLUSTER_SERVICE_CIDR 10.0.0.0/16`
- `CLUSTER_LOAD_BALANCER_CIDR 10.50.0.0/16`
- 4via6 `fd7a:115c:a1e0:b1a:0:1::/96`
- `STORAGECLASS_DEFAULT` and `_METADATA` = `ceph-block-replicated-nvme`;
  `_LONGTERM` = smb
- `COMMON_S3_ENDPOINT garage-gateway.garage.svc.cluster.local:3900`
- service logs shipped to `10.50.69.51:5170` (json_lines, tag
  `cluster=robbinsdale`) — but **no `talos.logging.kernel` kernel arg**, so
  unlike its siblings this cluster sends no kernel stream

Talos machines (amd64, heterogeneous):

| Node | Role | Address | Hardware |
|---|---|---|---|
| `tank` | control plane | 192.168.50.51 (DHCP), holds VIP | single 1 TB NVMe |
| `stone` | control plane | 192.168.50.82 (DHCP), holds VIP | single 1 TB NVMe |
| `titan` | control plane | 192.168.50.112 static, gw 192.168.50.1, holds VIP | moved off SFP after a multicast storm; the static address is what keeps the Ceph mons stable. Most disks of the three nodes. |

Talos machine config (talhelper):

- **extensions** — `amd-ucode`, `amdgpu`, `gvisor`, `i915`, `intel-ucode`,
  `realtek-firmware`, `thunderbolt`, `binfmt-misc`, `util-linux-tools` (a
  mixed AMD+Intel set, for mixed hardware in one node group)
- **kernel args** — `talos.platform=metal` only; no perf/mitigation tuning
  here
- **sysctls** — the same BBR / inotify / hugepages / userns base as Ottawa
- **kubelet** — `maxPods 250` via `extraConfig`, rotate-server-certificates
- **containerd** — shared global CRI customization
- no per-node patch directory exists for this cluster

The full inventory of Flux Kustomizations per namespace for this cluster is in
[`inventory.md`](inventory.md), generated from the pointer files themselves.

### St. Petersburg

`talos-stpetersburg` · Florida, USA · `SITE_ID` 3 · `rajsingh.info` · failover
target ottawa · `America/New_York`. 78 Flux Kustomizations across 39
namespaces.

- `clusterName k8s.stpetersburg.internal`, endpoint `:6443`
- Talos v1.13.8 · Kubernetes v1.36.3 (no drift)
- single control plane — `orin-0` — and it is **tainted**:
  `allowSchedulingOnControlPlanes=false` adds
  `node-role.kubernetes.io/control-plane:NoSchedule` so work lands on the
  sparks
- `LAN_CIDR 192.168.73.0/24` · `KUBERNETES_API_VIP 192.168.73.25`
- `CLUSTER_POD_CIDR 10.5.0.0/16` · `CLUSTER_SERVICE_CIDR 10.4.0.0/16`
- `CLUSTER_LOAD_BALANCER_CIDR 10.73.0.0/16`
- 4via6 `fd7a:115c:a1e0:b1a:0:3::/96`
- no Rook-Ceph here — `STORAGECLASS_DEFAULT` / `_METADATA` / `_LONGTERM` are
  all `local-path`
- `COMMON_S3_ENDPOINT garage-gateway.garage.svc.cluster.local:3900`
- logs shipped to `10.73.69.51:5170` — service logs via `machine.logging`
  (json_lines, tag `cluster=stpetersburg`), kernel logs via the
  `talos.logging.kernel` kernel arg

Talos machines (arm64):

| Node | Role | Hardware |
|---|---|---|
| `orin-0` | sole control plane, holds VIP 192.168.73.25 | NVIDIA Jetson Orin Nano Super dev kit; instance-type `jetson-orin-nano-super`; onboard M.2 NVMe for the OS (the SD card is unused); Tegra iGPU present but deliberately unused — no NVIDIA kernel modules loaded, minimal Talos schematic; 8 GiB RAM, so no hugepage reservation |
| `spark-0` | GPU worker | NVIDIA DGX Spark, GB10 Grace Blackwell superchip; instance-type `dgx-spark`; 1 GPU; ~4 TB NVMe; `vm.nr_hugepages` 2048 (4 GiB); RDMA rail 192.168.74.1/30, MTU 9000 |
| `spark-1` | GPU worker | NVIDIA DGX Spark, GB10 Grace Blackwell superchip; instance-type `dgx-spark`; 1 GPU; ~4 TB NVMe; `vm.nr_hugepages` 2048 (4 GiB); RDMA rail 192.168.74.2/30, MTU 9000 |

The `spark-0` ↔ `spark-1` RDMA / RoCE link is a direct point-to-point /30 with
MTU 9000, modules `ib_core`, `rdma_cm`, `rdma_ucm`, exposed to pods by
`rdma-shared-dp`.

Talos machine config (talhelper):

- **extensions** — `gvisor`, `nonfree-kmod-nvidia-lts`,
  `nvidia-container-toolkit-lts`, `binfmt-misc`, `util-linux-tools`
- **driver choice** — **nonfree**, not open-kernel-modules: the open modules
  crashed the GB10 on boot and the rollback was done over UEFI. The spark
  schematic also bakes in the `arm64.nobti` workaround.
- **kernel args** — `apparmor=0`, `mitigations=off`, `security=none`, auditd
  disabled, `net.ifnames=0` (five NICs can reorder, so NICs are pinned by
  hardware address), `nvidia_drm` modeset+fbdev
- **spark modules** — `nvidia`, `nvidia_uvm`, `nvidia_drm`, `nvidia_modeset`
  plus the RDMA stack
- **sysctls** — the BBR base plus `bpf_jit_enable=1` for Cilium, and
  `vm.min_free_kbytes` 4 GiB for multi-GiB weight loads
- **kubelet** — max-pods 250, `systemReserved` 4Gi, `kubeReserved` 4Gi,
  `evictionHard memory.available` 6Gi — added after `spark-0` was wedged twice
  by a 74 GB weight load with no reservations
- **containerd** — per-node; `default_runtime_name=nvidia` on the sparks only
- **GPU labels** — set by hand in `patches/node/spark-*.yaml` because NFD does
  not synthesize them on Talos (NFD itself does run, as `nfd-install` /
  `nfd-rules`): `nvidia.com/gpu.present`, `gpu.product=Blackwell`,
  `feature.node.kubernetes.io/pci-10de.present`, plus the
  `system-os_release.*` / `cpu-model.vendor_id` values gpu-operator's
  ClusterPolicy matches on

The full inventory of Flux Kustomizations per namespace for this cluster is in
[`inventory.md`](inventory.md), generated from the pointer files themselves.
