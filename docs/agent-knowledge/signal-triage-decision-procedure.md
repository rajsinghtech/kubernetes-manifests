# Signal triage: detector, coverage, and attention

When a failure went unnoticed, the first question is not “what alert should we
add?” It is “which layer failed?” A useful signal can be correctly evaluated
but never brought to a person, expressed as historical accumulation when the
operator needs current health, absent because its series never populated, or
misread because a valid gauge reset during startup. Those four failure shapes
look similar from the incident side and need different remedies.

There is one deliberate control case: a populated metric with useful labels
and no rule is a genuine alert-coverage gap. That is the case where adding an
alert is correct. Keep it separate from the four failure shapes below, where
adding another alert is the wrong first move.

## The decision procedure

Start with a bounded failure window: the component, cluster or tenant, first
and last observed symptoms, and the exact behavior that mattered. Then inspect
the live ruler and the metric data for that same window. Do not infer alert
coverage from a metric name, a rule file in Git, or a log line alone.

| Evidence | Diagnosis | Correct response |
| --- | --- | --- |
| The intended alert evaluated true and was firing, but nobody acknowledged or acted on it. | Attention and ownership failure. | Keep the alert. Fix routing, ownership, acknowledgement/escalation, and scheduled review. **There may be nothing to build.** |
| A rule is active because a lifetime counter or other historical value crossed a threshold, and it cannot return to normal after recovery. | Accumulator or non-clearable predicate. | Change the predicate to represent current health—usually a rate, ratio, windowed increase, age, or state gauge. Do not add a duplicate alert. |
| The metric name exists but the relevant series count is zero. | Instrumentation, collection, or label-contract failure. | Repair or enable the producer/scrape path first. A rule against an empty series is inert. |
| A timestamp-like gauge was healthy for a long range, then became exactly `0` after a pod restart. | Reset or initialization state misread as ancient staleness. | Treat `0` as unknown, gate on pod age/readiness, or expose validity separately. Fix the rule or emitter; do not add a duplicate alert. |

## Rule-authoring contract

There was no equivalent tracked contract in this repository. The Bhaiya
health-rule contract was written in the application repository, but the rules
that consume those signals live here. This is the manifests-side port of its
portable authoring requirements, not Bhaiya-specific metric names.

Before merging a rule, record:

- the user-visible capability, its healthy state, and its intentional or
  unknown states;
- a live series-count and label check for every input family. A successful
  empty query is not evidence that a rule can ever fire;
- the logical current-state identity. Prefer the newest attempt, active
  schedule, or current object over an immutable historical name or UID;
- the recovery path. A later success, deletion, pause, restart, or terminal
  controller state must have an explicit meaning, not be lost by a join;
- the threshold and `for:` from a healthy baseline and the expected effective
  detection delay; and
- tests for the sustained failure, a healthy/noisy target, recovery, and any
  intentional or unknown state. After loading, query the live ruler as well as
  the loader Job.

Do not add an `absent()` rule merely because an object disappeared unless an
independent expected-object inventory can distinguish deletion from exporter
loss. Do not use `Ready`, `Completed`, `MemoryPressure=False`, or a successful
controller process as a proxy for the capability the user needs without
checking currency and the downstream operation.

## Case law: five false-health signals

These are short precedents from the 2026-09-09 incident. Each has a different
detection question and therefore a different remedy; “add another alert” is
the right first move for none of these five.

### 1. Process readiness was not CNI capability

**Detection question:** Does `Ready` represent the operation users depend on,
or only that a process exists?

`kube-multus-ds` reported 4/4 with no readiness or liveness probe. The relevant
coupled images are visible at
`kubernetes/apps/base/kube-system/cilium-ottawa/app/patch-multus.yaml:15-36`,
with the same shape in the Robbinsdale patch at `.../kustomization.yaml:43-64`
and St. Petersburg at `.../patch-multus.yaml:14-35`. Sandbox `ADD` was timing
out while the DaemonSet still looked healthy. The shim and daemon also have to
be treated as one artifact: a host-installed shim polling an endpoint the
daemon does not expose is a capability failure, not a pod-readiness failure.

The fix is a capability probe against the daemon API, plus moving the raw
manifest, installed shim, and daemon together. The existing invariant in
`tools/check-versions.sh:367-391` catches raw-manifest/shim drift; the follow-up
must include the daemon too. This is why #2899/#2905 aligned the pair and added
probes, with rollout held for a staffed window.

### 2. Reconciled did not mean current

**Detection question:** Does `Ready=True` mean current, or merely successfully
reconciled at an older revision?

The Kustomizations were Ready while the Bhaiya Deployment still served an old
bookkeeping SHA. The exporter already exposes the needed currency field as
`revision: status.lastAppliedRevision` at
`kubernetes/apps/base/monitoring/monitoring-common/app/kube-state-metrics-config.yaml:77-94`,
while the existing alert at
`kubernetes/apps/base/mimir/mimir-ottawa/rules/flux.yaml:21-38` only asks about
`ready`. The alert was not wrong; its scope was readiness, not freshness.

The fix is a separate delivery-currency check: compare the Kustomization's
`lastAppliedRevision` and the workload's image/SHA with the intended Git
revision. Keep `FluxKustomizationNotReady` for reconciliation failure and do
not relabel a stale-but-Ready object as a current one.

### 3. A join dropped the stale schedule

**Detection question:** Would this signal change if schedule metadata were
paused, deleted, or temporarily absent—and is that change intentional?

`VeleroBackupStale` originally fired on fresh schedules while missing schedules
that were 26h or 49h stale: a join around per-attempt metadata allowed the
right-hand series to erase the schedule-level freshness signal. The corrected
rule computes freshness per schedule and gates it with the active schedule at
`kubernetes/apps/base/mimir/mimir-ottawa/rules/velero.yaml:55-80`. Its tests keep
the 26h/49h cases firing at
`kubernetes/apps/base/mimir/mimir-ottawa/rules/tests/velero_stale_test.yaml:8-63`
and ensure deleted or paused schedules do not resurrect historical alerts at
`:120-136`.

The fix is to choose the identity before joining: aggregate the latest
successful timestamp by schedule, then apply an explicit active-schedule gate.
If missing metadata is intended to clear the alert, say so; otherwise it is a
join/collection failure that needs a separate observation signal.

### 4. An immutable attempt was mistaken for current state

**Detection question:** Can a later successful attempt change the series this
alert evaluates, or is the predicate pinned to a historical object name, UID,
or Job?

The original `VeleroPodVolumeBackupFailed` and `MimirRuleLoaderFailing` shapes
selected immutable per-attempt records. A later success therefore could not
clear an old failed PVB or content-hashed loader Job. The source precedents are
`kubernetes/apps/base/mimir/mimir-ottawa/rules/velero-integrity.yaml:36-75`
and `.../rules/mimir-loader.yaml:9-17`; the latter's raw
`kube_job_status_failed > 0` is especially easy to leave latched by retained
Jobs.

The PVB fix (prepared in `5962f4f`) selects the newest scheduled Backup and
bounds orphan records by age; its recovery fixture is
`kubernetes/apps/base/mimir/mimir-ottawa/rules/tests/velero-integrity_test.yaml:136-153`.
The loader fix (prepared in `13745da`) requires a terminal failure reason and
joins it to the newest content-hashed Job, while the stale-success rule remains
the dead-man's switch. Test failed-then-success explicitly. A failure counter
is evidence of history, not automatically evidence of current failure.

### 5. A terminal delivery state was paged as an active outage

**Detection question:** Can this alert clear when the controller has genuinely
given up, and does its severity distinguish current user impact from blocked
future delivery?

`FluxHelmReleaseNotReady` is defined as a critical 15-minute `ready=False`
condition at
`kubernetes/apps/base/mimir/mimir-ottawa/rules/flux.yaml:60-77`. The reference
`flux-system/flux-operator` workload was healthy, but the HelmRelease was
`Stalled=True`, `MissingRollbackTarget`, with two upgrade failures. The runbook
records the evidence and owner-approved recovery at
`docs/agent-knowledge/flux-helmrelease-missing-rollback-target.md:7-18,20-43`:
the controller had given up and was not retrying, while future operator
upgrades remained blocked.

The immediate remedy is a deliberate one-off remediation reset, not repeated
reconcile attempts. The design remedy is to distinguish an active failed
workload from terminal upgrade debt in severity, routing, and ownership. A
critical that stays red while no outage is active trains operators to ignore
critical alerts; do not paper over that with a duplicate detector.

### Adjacent capacity case: a healthy condition hid starvation

**Detection question:** Does the condition measure actual safety, or only one
narrow eviction signal?

On St. Petersburg `orin-0`, `MemoryPressure=False` coexisted with less than
1 GiB available for a day and very little request headroom. The replacement
signal computes allocatable minus Running pod requests at
`kubernetes/apps/base/mimir/mimir-ottawa/rules/node-health.yaml:53-94`;
the Spark rule explicitly warns that an OOM can occur while MemoryPressure stays
false at `.../rules/stpetersburg-memory.yaml:39-60`. The fix was to alert on
schedulable headroom and inspect working set/eviction order, not to infer node
capacity from the condition alone.

The empty-series row is an important guardrail around the control case. A
successful empty query proves only that the query syntax is accepted; it does
not prove that a rule can ever evaluate true.

## 1. Was there already a correct alert?

Query the live ruler for the alert and its labels, then check the notification
path. Establish all of the following for the failure window:

- the rule was loaded and healthy;
- its expression became true for the affected target;
- the expected instance labels identified the target rather than collapsing it
  into a fleet-wide aggregate;
- Alertmanager received the firing alert; and
- the configured receiver, grouping, repeat interval, and escalation path made
  it visible to the responsible human or agent.

If those facts hold and nobody acted, this is not missing detection. Adding a
second rule will create another copy of the same unattended signal and may
make grouping noisier. The honest outcome is:

> Nothing new needs to be instrumented or alerted. A named owner, an
> acknowledgement deadline, escalation, or a scheduled sweep is missing.

An attention mechanism cannot create a human who is looking. If there is no
continuously staffed responder, a recurring sweep is a process control and
should be described as one. A good sweep checks firing alerts, unowned alerts,
and alerts that have remained unacknowledged past their response target.

Do not reinterpret a correctly firing alert as a coverage gap merely because
the incident lasted longer than the alert. The question is whether the signal
reached an accountable observer, not whether another rule can say the same
thing.

## Control case: is the metric present but unwired?

If no correct alert instance existed, inspect the metric before designing a
rule. This is the one case in this guide where adding alert coverage is the
right outcome. Query the series count with the labels that the proposed
predicate will use. For example, check the total population and the dimensions
independently:

```promql
count(bhaiya_mcp_proxy_requests_total)
count by (provider, result, status_class) (bhaiya_mcp_proxy_requests_total)
```

Use the actual metric and label contract for the component; the example is only
the shape of the check. Confirm that:

- the producer is running and the series are populated in the affected
  tenant/cluster;
- the failure has a stable, bounded label value;
- healthy targets have a usable baseline for comparison; and
- the metric's type and update behavior match the intended expression.

Only then add alert coverage. Prefer the smallest predicate that represents
the failure, with target labels such as provider, cluster, route, or operation
where they are bounded and actionable. A fleet-wide ratio can hide one broken
provider behind healthy traffic from the rest of the fleet.

For counters, alert on a window rather than the lifetime value. A common shape
is a failure ratio with a meaningful-traffic floor:

```promql
(
  sum by (cluster, provider) (rate(requests_total{result="error"}[5m]))
  /
  sum by (cluster, provider) (rate(requests_total[5m]))
) > 0.05
and on (cluster, provider)
sum by (cluster, provider) (rate(requests_total[5m])) > 0.1
```

The threshold must come from a healthy baseline, not from the incident value.
The traffic floor prevents a single old or low-volume event from producing an
unhelpful ratio. If no traffic is present, use a separate availability or
scrape signal when that absence matters; do not manufacture an outage from an
undefined ratio.

Every new rule should have tests for:

1. the sustained failing shape becoming pending and then firing;
2. a healthy, normally noisy target remaining inactive; and
3. recovery making the alert inactive again.

After the rule passes offline tests, verify the delivery chain: the loader
accepts it, the live ruler exposes the expected group and rule, and the live
labels discriminate the failing target from healthy ones. A successful loader
Job is not enough if it silently omitted a rule file or group.

## 3. Can the alert ever clear?

Ask this question for every new or suspicious rule:

> Can this alert return to inactive on its own when the underlying failure is
> fixed, without restarting or resetting the producer?

Names ending in `_total` are normally monotonic counters. A predicate such as
`errors_total > 0` records that an error happened once; it does not describe
whether the error is happening now. It will remain true after a perfect
recovery. The same trap appears when a timestamp, generation, or historical
status is compared without an age or window that can return to normal.

Replace the historical predicate with the current-health expression that fits
the signal:

- `rate()` or a windowed `increase()` for event frequency;
- a ratio of failing events to total traffic for per-request health;
- an age calculation for “no success recently”; or
- a current state gauge with an explicit healthy value.

Keep lifetime counters as forensic evidence and dashboards when useful. They
are not automatically suitable alert predicates. If historical knowledge is
important, expose it as a separate recording or audit signal rather than
letting a page stay red forever.

The recovery test is mandatory for this class: hold the bad value long enough
to fire, restore healthy input, and confirm that the alert becomes inactive.
If it cannot, either the predicate or the intended semantics are wrong. Do not
silence a permanently red alert and do not add another alert beside it.

### 3.1 Does the identity describe an attempt or current state?

Some exporters expose one immutable series per operation attempt rather than
one series per current target. A PodVolumeBackup, for example, carries the
Backup and pod identities of the attempt that created it. A query that selects
every `phase="Failed"` child therefore records an old failure forever when a
later run succeeds; selecting by pod name can still fail when a replacement
pod has a new name or UID.

When the exporter does not expose a durable PVC or target identity, reduce the
parent attempts to the newest current attempt first, then join child failures
to that parent. Keep any manual/orphan fallback bounded and explicit. Do not
pretend that a child-attempt label is current protection state, and do not
silently discard the limitation: a new exporter contract is needed for
per-volume state when the parent boundary is not sufficient.

The fixtures for this shape must include an older failed child followed by a
successful newer attempt with a replacement identity, a failure in the latest
attempt, and a first-ever failed attempt. The recovery case is the essential
test: a successful current attempt must make the old failure inactive.

## 4. Is zero a reset rather than stale?

A timestamp gauge can have a third state that an ordinary numeric comparison
does not represent: “the process has not completed a successful reconcile since
startup.” Many emitters encode that state as `0`. The expression
`time() - last_success_timestamp_seconds` interprets `0` as the Unix epoch,
so it reports maximal staleness immediately after every pod start. A `for:`
period only delays the false page; it does not make the predicate meaningful.

The distinguishing check is a range query, not an instant query. Examine at
least the preceding day of samples together with pod start time:

- a series that stayed within its healthy age band for hours and ends in one
  exact `0` at the restart is a reset;
- a series that was `0` for the whole range is never-populated or never
  successful; and
- a series that remains nonzero but ages past its threshold is a genuine stale
  success signal.

The first two cases have the same current value and opposite diagnoses. A
series count can show that the time series exists, but only the range history
can distinguish a reset from a series that was never useful.

The fix belongs in the rule or emitter:

- require `last_success_timestamp_seconds > 0` before evaluating staleness,
  treating zero as unknown rather than as an old success;
- gate the stale check on pod age or readiness and allow a startup grace
  period; or
- emit a separate initialized/valid gauge and alert on “never succeeded” with
  an explicitly chosen startup policy.

Test all three transitions: healthy nonzero samples, pod restart with zero,
and a genuinely old nonzero timestamp. The zero-after-restart case must not
page merely because a deploy happened; the old nonzero case must still fire.
This is neither the empty-series instrumentation problem nor the
non-clearable-accumulator problem: the metric exists and can be healthy, but
its initialization semantics are being interpreted incorrectly.

## Timing and handoff

Record the effective detection delay, not just the rule's `for:` value. The
end-to-end estimate includes the scrape interval, ruler evaluation cadence,
the `for:` hold, and notification grouping or delivery delay. A rule with a
five-minute hold does not necessarily notify five minutes after the first bad
request.

For each finding, write down:

```text
Failure window and affected target:
Evidence from metric series and live ruler:
Classification: attention / missing rule / non-clearable predicate / empty series
Existing alert and notification owner:
Chosen remedy and why the other remedies do not apply:
Can it clear on recovery? How was that tested?
Effective detection and notification delay:
Verification still required:
```

This keeps “we had an alert and nobody looked,” “the rule records history
forever,” “the metric never populated,” and “the gauge reset during startup”
separate. All four can produce hours of misleading silence or noise from an
operator’s perspective. The populated-metric/no-rule control case remains the
explicit exception where adding one well-tested alert is the right cure.
