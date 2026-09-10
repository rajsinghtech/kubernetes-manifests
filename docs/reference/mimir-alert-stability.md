# Mimir alert-stability diagnostic

`tools/check-mimir-alert-stability.py` is a live, report-only diagnostic for
alert rules whose condition churns without surviving its `for` duration. It is
not a `PrometheusRule`, does not emit an Alertmanager signal, is not deployed
as a Kubernetes workload, and does not make findings fail CI. Exit status `2`
means the live sweep was incomplete; findings still exit `0`. A human must
interpret every candidate before changing a rule.

The default output is deliberately candidate-oriented. It filters out
resolution-level one-sample activity and leaves edge-censored observations in
the inconclusive bucket. Use `--all` when the raw observations or evaluator
state details are needed; the filter hides noise from the normal report, not
from the diagnostic.

For every native alert rule and tenant, it evaluates the complete expression
through Mimir's `query_range` API. It applies the rule labels to the vector
result and groups samples by the resulting alert output labels, rather than by
each source metric label or response item. That is important for Flux:
`revision` and `reason` can change while `(cluster, namespace, name, path)`
remains the same logical Kustomization. Flux-escaped `$$` sequences in native
rule expressions are reduced to their deployed literal `$` form before the
live query, so the diagnostic evaluates the expression Mimir actually runs.

The report contains these measurements for a candidate instance:

- `max_active` is the maximum continuous active duration observed. With a
  one-minute step, N adjacent active evaluations span `(N - 1)` minutes, so
  this is a lower bound at the sampling resolution.
- `transitions` counts active/inactive changes between adjacent evaluations;
  `transition_frequency` expresses that count per hour of lookback.
- `active_duration_for_ratio` is `max_active / for`.
- `current_active` reports the expression's presence at the final sampled
  evaluation. `duration_censored=true` means an active run touches the start or
  end of the range and may continue outside it.

The raw observation is `high-churn, never-sustained` when it has at least two
active runs, a positive `for`, a ratio below one, and no edge-censored run. The
same evidence with an edge-censored run is `high-churn, range-censored`; extend
the lookback before calling it never-sustained. A quiet rule and one new
condition that has not yet reached its hold are not observations.

## Candidate output and triage

The default minimum active-duration floor is one complete sample step. With a
one-minute step, a one-sample run has `max_active=0s`; when it is part of a
raw churn observation it is classified as `suppressed-short-activity`. A
single new run is also not a candidate because there is not yet enough
activity to establish churn. Two adjacent active samples span one minute and
can be a candidate. Override the floor with `--min-active-duration`, or use
`--all` to print every raw high-churn observation regardless of the floor.
The summary always reports the counts for `candidates`,
`suppressed_short_activity`, and `inconclusive_range_censored`.

Default output categories have deliberately non-alerting names:

- `candidate` means sustained activity was observed, but it fell short of the
  configured `for` duration. It is a question for human triage, not a defect
  verdict and not permission to retune the rule.
- `suppressed-short-activity` means the raw churn evidence did not clear the
  minimum duration floor. It is available in `--all` output and is not a rule
  finding.
- `inconclusive-range-censored` means the active run touched a query-range
  edge. Extend the sample before deciding anything.
- `state-mismatch` means Mimir reported a pending or firing alert while the
  full expression was currently inactive. This is evaluator/state evidence,
  not proof that the rule is unreachable.

The KubeletDown fixture makes the intended discrimination executable:
`up{job="kubelet"} == 0` active for three minutes against `for: 15m` is a
`candidate` with ratio `0.2`, while separated one-sample spikes are
`suppressed-short-activity` with `max_active=0s`. The live Robbinsdale
KubeletDown case was ultimately a threshold question—real `up == 0` activity
on `tank`, but no evidence that the current-state rule shape was wrong—not an
automatic fix request.

The diagnostic also reads Mimir's current rules API and reports a separate
`state-mismatch` line when Mimir says an alert is `pending` or `firing` while
the full expression is currently inactive for that same output-label set. The
rules API snapshot is taken after the range queries so the two observations
are close in time. This is evidence to investigate evaluator timing, stale
state, or label identity; it is never converted into a new alert by this tool.

## Invocation

The default sweep covers the three cluster tenants, six hours, and one-minute
samples:

```console
MIMIR_API_URL=http://mimir-gateway.mimir.svc.cluster.local:8080/prometheus/api/v1 \
  tools/check-mimir-alert-stability.py
```

Use repeated `--tenant` or `MIMIR_TENANTS` to select tenants, `--rule-name` to
focus on a rule, `--lookback`/`--step` to change the sampling window,
`--min-active-duration` to change the default candidate floor, and `--all` to
show suppressed observations and state mismatches. The live sweep is
intentionally bounded and concurrent, but remains an operator diagnostic
rather than a merge gate.

## Fixture proof

`tools/tests/fixtures/alert-stability-unknown-toggle.json` models the output of
the full Flux expression while the underlying readiness state includes an
`Unknown -> True -> Unknown` transition. The two separated Unknown waves are
asserted as `high-churn, never-sustained`, with a non-zero transition
frequency, rather than being silently treated as no finding. The test also
proves that split response items with the same output labels are merged, that
pending and firing state is reported when the expression is inactive, and that
a current matching expression is not called stale.

`tools/tests/fixtures/alert-stability-kubeletdown.json` pairs a three-minute
KubeletDown flap against `for: 15m` with separated one-sample spikes. The
first is a candidate; the second is explicitly suppressed by the one-step
floor. This prevents a future change from treating a silently empty default
report as proof that the diagnostic is broken, while also preventing a
single-sample probe blip from being presented as a rule defect.

## FluxKustomizationUnknown

The diagnostic deliberately does not change
`FluxKustomizationUnknown`. Flux exposes `Ready=Unknown` with
`reason=Progressing` and `message=Reconciliation in progress` during normal
reconciliation. Its rule's `for: 30m` is the persistence guard; short Unknown
waves should not page. The diagnostic may report those waves as high churn so a
human can see their frequency, but that is not evidence to extend the hold or
to require raw-series identity. The rule's aggregation keeps the logical
Kustomization stable while source `revision` and `reason` labels churn.

This is deliberately diagnostic output, not a recommendation to alter the
alert. The already-reviewed behavior remains: `for: 30m` is doing its job, the
flap is fleet-wide rather than Robbinsdale-specific, and requiring same-series
identity would break on legitimate revision/reason churn.

## Historical live sweep snapshot (unfiltered)

On 2026-09-09 at 19:42 UTC, the six-hour/one-minute sweep ran all 177 native
alert rules against all three tenants: 531/531 expression queries completed.
This was captured before the candidate filter and is equivalent to the raw
`--all` view: it reported 124 `high-churn, never-sustained` instances, 2
`high-churn, range-censored` instances, and 1 pending/firing-state mismatch.
The raw high-churn observation counts were Ottawa 21, Robbinsdale 91, and St.
Petersburg 14; the counts are observations, not alert conditions.

Besides `FluxKustomizationUnknown` (78 instances), the high-churn report
contained:

| Rule | Tenant(s) | Instances |
| --- | --- | ---: |
| `FluxKustomizationNotReady` | all three | 32 |
| `BhaiyaDeploymentCurrencyStale` | Ottawa | 1 |
| `BhaiyaKubeletRuntimeErrors` | Ottawa | 1 |
| `BhaiyaMCPProviderUpstreamErrorRatio` | Ottawa | 1 |
| `BhaiyaOpenCostCacheStale` | Ottawa | 1 |
| `BhaiyaReconcileWorkspaceHandlerFailure` | Ottawa | 1 |
| `BhaiyaServiceP99LatencyRegression` | Ottawa | 1 |
| `BhaiyaVeleroPodVolumeBackupCoverageUnavailable` | Ottawa | 1 |
| `BhaiyaVeleroPodVolumeBackupLabelCoverageStalled` | Ottawa | 1 |
| `BhaiyaWorkspaceImagePublicationProbeUnavailable` | Ottawa | 1 |
| `KubeAPIErrorsHigh` | Ottawa | 2 |
| `NodeHighCpuUsage` | Robbinsdale | 1 (range-censored) |
| `PodNotReady` | Robbinsdale | 1 |
| `ProbeFailed` | Robbinsdale, St. Petersburg | 2 |
| `ProbeSlowResponse` | St. Petersburg | 1 |
| `PrometheusTargetDown` | Ottawa | 1 |
| `ZotHighPushLatency` | Ottawa | 1 (range-censored) |

The one state mismatch was in Ottawa: `SmartDeviceHighTemperature` was
reported `pending` while its expression was inactive. It needs live evaluator
and exporter triage; this diagnostic does not page on it.

The sweep did not report `VeleroBackupFailed` or `NodeKernelOOMKill` as short
transient-window defects because both fixes are already in merged PR #2928:
the Velero alerts use current newest-Backup state, and NodeKernelOOMKill keeps
the one-hour event lookback with a five-minute hold. The separate static
`tools/check-mimir-alert-windows.py --max-window 1h` scan is clean.
