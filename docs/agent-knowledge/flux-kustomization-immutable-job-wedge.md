# Flux Kustomization wedge: Renovate changed a terminal Job

Date: 2026-09-08 UTC

## Incident

The Flux Kustomization `kopiur-velero-home-restore-proof-target` in
`flux-system` remained `Ready=False` for roughly six hours with:

```text
Job/velero-home-ottawa-restore-proof-r2-verify dry-run failed (Invalid):
spec.template: field is immutable
```

This was a permanent reconciliation failure, not a transient Job failure. The
Kustomization owns the proof target path, including the restore objects,
verifier RBAC, and the verifier Job. Because the path is managed with
`prune: true`, a failed reconciliation freezes every desired change in that
path; it is not limited to the object named in the error.

The immediate consequence was important: the corrected verifier from `#2869`
never ran. The restore data was valid, but its green proof artifact was blocked
by GitOps delivery. The repository therefore read as though the correct fix had
shipped while the standing artifact in the cluster was still the failed Job.
That withholding of a correct fix is the part a bare `Ready=False` condition
does not make obvious.

## Exact mechanism

The sequence was:

1. `#2865` created the one-shot Job
   `velero-home-ottawa-restore-proof-r2-verify`.
2. The Job reached a terminal `Failed` state. A terminal Job still has an
   immutable Pod template. The one-shot Job trap was dormant at this point;
   the terminal object did not change its own Git manifest.
3. Renovate's `#2866` changed the Kopia image digest from the original digest
   to `89fd95e`. That changed the Job's Pod template. Flux's server-side apply
   dry-run rejected the update because `spec.template` is immutable.
4. `#2869` added `verify-r2-corrected.yaml` to fix the verifier's comparison.
   The corrected Job had a different name, but Flux could not get past the
   still-invalid old Job, so it was never created.
5. Deleting only the live old Job would not have fixed the wedge. The old
   manifest remained the outer owner in Git, so Flux would recreate or reapply
   it. Resetting the Job age to seconds would have been the tell for that
   mistake.

The corrected verifier was blocked by a failed proof Job, not by the restore
itself. The independent content evidence showed exactly one source-only entry:
the root `lost+found` directory created by the filesystem. There were no
target-only entries. All 37 files had equal per-file SHA-256 values and both
sides contained 7,211,009 bytes. `#2869` correctly made that comparison
symmetric.

## Why the API server was also being hammered

The Kustomization has a normal `interval: 30m`, but its failure path has
`retryInterval: 1m`. The live evidence showed about two rejected server-side
dry-runs per minute for roughly six hours. The observed `KubeAPIErrorsHigh`
alert for `resource=restores` and `verb=APPLY` tracked that retry load. Both
`FluxKustomizationNotReady` and `KubeAPIErrorsHigh` cleared when `km#2874`
merged and the Kustomization could reconcile; that timing proved the link
rather than leaving it as a correlation inferred from the logs.

Thus `Ready=False` understated the incident. The Kustomization was stale and
was actively generating API-server error load. That behavior is easy to miss
when looking only at the readiness condition.

## Fix in `#2874`

The durable fix was Git-side:

- remove the obsolete `verify-r2.yaml` from the Kustomization resources and
  delete the old manifest, allowing `prune: true` to remove the old Job;
- keep the corrected verifier under the new name
  `velero-home-ottawa-restore-proof-r2-verify-corrected`, avoiding an immutable
  same-name replacement;
- add `kustomize.toolkit.fluxcd.io/force: enabled` to that verifier.

Flux then pruned the obsolete Job, created the corrected verifier, and the
Kustomization returned `Ready=True`. The corrected Job succeeded. The force
annotation is the intended class fix for this particular kind of harmless,
rerunnable verifier: a future Renovate digest change should replace the
immutable Job instead of wedging its Kustomization.

The annotation has been verified on the live corrected object, but the next
Renovate digest bump has not happened yet. We have therefore verified that the
annotation applies, not that Flux actually performs the force replacement on a
subsequent immutable-template change. Only a real bump proves that final
behavior.

This annotation must not be blanket-applied to every Job. Force replacement is
appropriate only where rerunning or replacing the one-shot workload is
intentional and safe. A Job with a destructive or non-idempotent purpose needs
a different lifecycle decision. `ttlSecondsAfterFinished` is not a complete
solution: it may eventually remove the conflict, but it does not protect the
window before the TTL expires and does not make an unappliable Git revision
valid.

The repository sweep found no other Flux-managed instance with this exact
signature. The St. Petersburg snapdel Job is Kopiur-Repository-owned rather
than Flux-managed, so it cannot wedge a Flux Kustomization and does not need
the annotation.

## Detection and attention

The existing `FluxKustomizationNotReady` alert worked. It is a critical alert
with a 15-minute `for:` period, and it fired for this exact Kustomization for
the full six-hour wedge. Only six alerts were firing fleet-wide, so saturation
was not the explanation. The correct conclusion is not that the repository
lacked an instrument; the signal was delivered and nobody acted on it.

At the time, the default Alertmanager route grouped alerts by alert name,
cluster, and job, sent them to the general Discord receiver, and repeated them
after 12 hours. That is a routing and attention path to review, not evidence
that the alert rule was absent or broken. The incident's strongest finding is
simply that a correct critical signal can remain unacknowledged for hours.

No duplicate stuck-Kustomization rule is warranted. The unfilled gap is the
attention path:

- who owns a critical Flux readiness alert;
- how it becomes an acknowledged incident rather than an unattended firing
  alert;
- whether grouping makes the specific Kustomization visible; and
- what happens when nobody is continuously watching the alert channel.

An attention mechanism cannot create a human or agent that is looking. A
scheduled 30-minute alert sweep, as used during this incident, is therefore a
legitimate durable control when there is no staffed on-call path. It is a
process change, not a new detector, and should be described honestly as such.

## Two diseases, two cures

These two incidents were both invisible for hours, but they were not the same
observability failure:

| Incident | What existed | Actual gap | Correct cure |
| --- | --- | --- | --- |
| Flux Job wedge | `FluxKustomizationNotReady` fired correctly for six hours | Nobody watched or owned the critical signal | Ownership, acknowledgment/escalation, and scheduled sweeps |
| MCP response-body timeout | `bhaiya_mcp_proxy_requests_total` was populated, but no rule existed | Metric coverage had never been turned into alert coverage | One windowed metric-ratio alert |

The MCP proxy incident is therefore different. Its upstream response-body idle
timeout was a real failure with no alert coverage, despite having usable metric
data. A live Mimir snapshot showed lifetime counter totals of 4,848
`success`, 7,519 `upstream_error`, 2 `server_error`, and 3 `client_error`
requests. Of the upstream errors, 7,314 belonged to
`provider="grafana",status_class="2xx"`; the upstream had answered
successfully and the proxy then tore down the response body during the copy.
The remaining provider/status combinations were single-digit noise by
comparison.

Those totals are evidence, not a rule predicate. They are accumulators and a
raw-count alert would remain high forever after recovery. The rule should use
a windowed ratio, for example:

```promql
(
  sum by (cluster, provider) (
    rate(bhaiya_mcp_proxy_requests_total{
      result="upstream_error",
      status_class="2xx"
    }[5m])
  )
  /
  sum by (cluster, provider) (
    rate(bhaiya_mcp_proxy_requests_total[5m])
  )
) > 0.05
and on (cluster, provider)
sum by (cluster, provider) (
  rate(bhaiya_mcp_proxy_requests_total[5m])
) > 0.1
```

The threshold and meaningful-traffic floor need normal-baseline review, but
the shape is the important part: it alerts on a sustained fraction of failing
requests and clears when the five-minute window recovers. If there is no
traffic, the ratio is undefined and should not manufacture an outage; scrape
or service-availability signals own that case. The lifetime counters will
still read `7,519` after recovery, so anyone investigating later must read
the rate or ratio rather than infer current health from the accumulator.

With the existing 30-second ServiceMonitor scrape, an approximately one-minute
ruler evaluation cadence, a `for: 5m`, and Alertmanager's one-minute
`groupWait`, the notification would arrive nominally about seven minutes
after a sustained failure begins, with an honest worst-case around eight to
nine minutes. Human acknowledgment is a separate delay.

The Flux incident needs no second readiness detector. Its
`FluxKustomizationNotReady` signal fired correctly for six hours. Its cure is
ownership, acknowledgment, escalation, and a scheduled sweep when nobody is
continuously watching. Adding another rule for the same condition would be
redundant; failing to add metric coverage for the MCP failure would leave a
different class of outage invisible. The instinctive response to both failures
is “add an alert”; that would be redundant for Flux and exactly right for MCP.

## Validation lesson

The existing CI rendered the manifests but did not ask a live API server to
accept the update against the existing Job, CRD schemas, defaults, and
webhooks. A server-side dry-run would have exposed this rejection before
merge, as it also would have exposed the other recent live-API wedge classes.

Putting that check in arbitrary pull-request jobs would require production
credentials reachable from PR-controlled code. That security surface is not
worth opening as an emergency change. The current recommendation is:

1. keep the existing Flux alert and improve the ownership/attention process;
2. use a scheduled sweep when no continuously staffed responder exists; and
3. consider a later, separately secured all-cluster dry-run pilot with an
   untrusted-render/trusted-validator boundary, short-lived credentials, and
   explicit handling for Flux force replacement and pruning.

The durable finding from this incident is therefore twofold: a Renovate-managed
image digest can wedge a completed Flux-owned Job, and an alert can work
perfectly while the outage continues. The first is fixed in Git with the
correct lifecycle and force annotation; the second requires attention and
ownership, not another copy of the same alert.
