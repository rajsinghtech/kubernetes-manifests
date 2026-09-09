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
it indicates a selector or label-contract defect and fails the check. The
lookback is therefore part of the meaning of “present”; choose it long enough
to cover the expected scrape cadence.

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

This is an operational, periodic check rather than a pull-request check. A
PR runner normally cannot reach the tenant-scoped Mimir service, and a
synthetic fixture cannot prove the exporter-to-Mimir label contract. Run the
one-shot checker from a small in-cluster monitoring process for each tenant,
with the native rules supplied from the same Git revision, and send a
non-zero result to Alertmanager. The existing
`mimir-rule-completeness` deployment is the model for this placement: it has
Mimir service access, iterates over all three tenants, and posts independent
checker alerts directly to Alertmanager so a broken Mimir rule cannot silence
the checker itself.

The checker intentionally does not change or allowlist rules. On its first
live run it may expose already-existing label-contract defects; those should
be fixed in their owning rule changes rather than hidden from this signal.
