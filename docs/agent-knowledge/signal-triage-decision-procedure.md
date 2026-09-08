# Signal triage: detector, coverage, and attention

When a failure went unnoticed, the first question is not “what alert should we
add?” It is “which layer failed?” A useful signal can be absent from the
system, present in the metrics but absent from the rules, correctly evaluated
but never brought to a person, or expressed as historical accumulation when
the operator needs current health. Those cases look similar from the incident
side and need different remedies.

## The decision procedure

Start with a bounded failure window: the component, cluster or tenant, first
and last observed symptoms, and the exact behavior that mattered. Then inspect
the live ruler and the metric data for that same window. Do not infer alert
coverage from a metric name, a rule file in Git, or a log line alone.

| Evidence | Diagnosis | Correct response |
| --- | --- | --- |
| The intended alert evaluated true and was firing, but nobody acknowledged or acted on it. | Attention and ownership failure. | Keep the alert. Fix routing, ownership, acknowledgement/escalation, and scheduled review. **There may be nothing to build.** |
| The required metric has populated series with useful labels, but no rule evaluates the failure. | Alert-coverage failure. | Add one discriminating rule, with tests for failure, healthy state, and recovery. |
| A rule is active because a lifetime counter or other historical value crossed a threshold, and it cannot return to normal after recovery. | Accumulator or non-clearable predicate. | Change the predicate to represent current health—usually a rate, ratio, windowed increase, age, or state gauge. Do not add a duplicate alert. |
| The metric name exists but the relevant series count is zero. | Instrumentation, collection, or label-contract failure. | Repair or enable the producer/scrape path first. A rule against an empty series is inert. |

The last row is an important guardrail around the second one. A successful
empty query proves only that the query syntax is accepted; it does not prove
that a rule can ever evaluate true.

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

## 2. Is the metric present but unwired?

If no correct alert instance existed, inspect the metric before designing a
rule. Query the series count with the labels that the proposed predicate will
use. For example, check the total population and the dimensions independently:

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

This keeps “we had an alert and nobody looked,” “we had data but no rule,”
and “the rule records history forever” separate. All three can produce hours of
silence from an operator’s perspective, but only one of them is fixed by
adding an alert.
