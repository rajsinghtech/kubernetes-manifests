# Mimir label-contract check

The native Mimir rule fixtures validate PromQL syntax and rule behavior for
the labels represented by the fixture. They cannot validate the contract
between an exporter, scrape relabeling, remote write, and the labels actually
stored in Mimir. A fixture can therefore agree with a rule while both disagree
with live data.

`tools/check-mimir-label-contract.py` checks that contract against a tenant's
live Mimir series API:

1. Read each native alert and recording rule expression and extract its vector
   selectors.
2. Query `/prometheus/api/v1/series` for the bare metric name and for the full
   selector, using `X-Scope-OrgID`, `start`, and `end`.
3. Fail when the metric family exists in the selected lookback but the full
   selector matches no series.

The family query is the important false-positive guard. A family with no
series in the selected lookback is treated as absent and skipped: the
component may be quiet or not deployed in that tenant. A family that is
present but has no series matching the rule's labels is different evidence;
it is a candidate selector or label-contract defect and fails the check. The
lookback is therefore part of the meaning of “present”; choose it long enough
to cover the expected scrape cadence. It is not, by itself, proof of a
defect: a healthy alert such as `FluxInstanceNotReady` also has a present
family and zero matches while every live series is `ready="True"`.

## Triage status

The first 24-hour live sweep on 2026-09-09 produced 142 present-family,
zero-selector observations across the three tenants (31 Ottawa, 53
Robbinsdale, and 58 St. Petersburg). That number is a candidate count, not a
finding count. The `/series` API does not provide the rule's applicability or
the expected values of its condition labels, so it cannot produce an honest
three-way `broken`/`not-applicable`/`quiet` partition on its own.

The ground-truthed cases are:

- No current Kopiur selector is proven broken. The pre-#2924 selectors did
  fail against a family whose live labels had `namespace="kopiur-system"` and
  `exported_namespace="home-assistant"`; after #2924, St. Petersburg and
  Robbinsdale are 14/14, and the two Ottawa repository observations are
  St. Petersburg-specific and not applicable.
- `FluxInstanceNotReady` is a known healthy-quiet control: its family exists,
  all live series are `ready="True"`, and `ready!="True"` matches nothing.
  The control appears in all three tenant sweeps.

The current checker therefore must not send every non-zero exit to
Alertmanager. A rule-specific applicability/metric-contract declaration (or
another independent source of expected labels) is required before a periodic
dead-rule alert can distinguish the historical Kopiur mismatch from a normal
quiet condition. The offline test includes both the Kopiur pre/post regression
and the healthy Flux counterexample to keep this limitation visible.

The other observation-quality failure is statically detectable. Run
`tools/check-mimir-alert-windows.py` to find `increase()`, `rate()`, or
`irate()` alert expressions whose range is at most a few scrape intervals and
whose `for` is zero. With the repository's 5-minute threshold, the current
rule set originally reported two locations: `VeleroBackupPartiallyFailed` and
`VeleroBackupFailed`. The former is fixed in this change; the strict scan now
reports one remaining location, `VeleroBackupFailed`, as a separate
counter-based finding. `NodeKernelOOMKill` is the adjacent broader case
(`increase(...[10m])` with `for: 0m`) and is reported when the threshold is
raised. Because the native rule files are shared, each location is loaded for
all three Mimir tenants.

Rules are shared across tenants. Selectors that explicitly exclude the
current tenant with a `cluster` matcher are skipped, because they are not
expected to match that tenant. Other selectors are checked normally.

## Invocation

The checker needs a tenant and live Mimir access:

```console
MIMIR_TENANT=talos-stpetersburg \
MIMIR_API_URL=http://mimir-gateway.mimir.svc.cluster.local:8080/prometheus/api/v1 \
  tools/check-mimir-label-contract.py --lookback 24h
```

Exit status `0` means every present family had at least one matching series;
absent families are reported as skipped. Exit status `1` means at least one
present family had zero full-selector matches. Exit status `2` means the rule
files or Mimir API could not be checked safely.

The offline test uses the Kopiur label contract as a regression proof. The
pre-#2924 selector with `namespace="home-assistant"` fails because live
series carry `namespace="kopiur-system"` and
`exported_namespace="home-assistant"`. The post-#2924 selector using
`exported_namespace` passes. The same test includes an absent metric family,
which is skipped rather than reported as a defect.

## Where it runs

This is intended to be an operational, periodic check rather than a
pull-request check. A PR runner normally cannot reach the tenant-scoped Mimir
service, and a synthetic fixture cannot prove the exporter-to-Mimir label
contract. Once the triage metadata exists, run the one-shot checker from a
small in-cluster monitoring process for each tenant, with the native rules
supplied from the same Git revision, and send only classified defects to
Alertmanager. The existing
`mimir-rule-completeness` deployment is the model for this placement: it has
Mimir service access, iterates over all three tenants, and posts independent
checker alerts directly to Alertmanager so a broken Mimir rule cannot silence
the checker itself.

The checker intentionally does not change or allowlist rules. Until the
applicability/condition distinction is made mechanical, its non-zero result
is diagnostic output only; wiring it as an alert would create a false-positive
signal that should not be shipped.
