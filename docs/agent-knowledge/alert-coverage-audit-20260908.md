# Alert coverage replay — 2026-09-08

This is a read-only replay of existing Bhaiya and infrastructure alerts against
the incidents that motivated them. No alert rules were changed.

## Results

| Alert | Result | Evidence and qualification |
| --- | --- | --- |
| `KubernetesJobFailedRecently` | **Can fire** | The current #2833 predicate uses `kube_job_status_failed` and recent start time. In the #2809-shaped Mimir-loader failure, `BackoffLimitExceeded` became true around 20:50 UTC and the expression would have fired around 20:55 with its five-minute `for`. The old #2828 predicate required series the failed Job did not expose. The positive fixture passes separately, but `job_failures_test.yaml` is not registered in the normal test runner. |
| `VeleroScheduleVolumeCoverageRegressed` | **Can fire** | The 3-to-1 completed-run PVB fixture fires after its 15-minute `for`; the recording series exists in all three tenants. The alert is currently firing for the corresponding persistent under-selection shape. |
| `VeleroPodVolumeBackupFailed` | **Can fire** | The positive `phase="Failed"` fixture fires, a newer success clears an older failure, and `phase="Canceled"` does not fire. A genuine Failed-PVB alert remains live in Robbinsdale. |
| `GarageClusterUnhealthy` | **Would have fired** | `cluster_healthy == 0` held through the roughly four-and-a-half-hour #725 incident, well beyond its 15-minute `for`; seven-day history also shows the alert firing in Ottawa and Robbinsdale. This is a historical replay, not a unit-tested result: `garage_test.yaml` has no fixture for this exact alert, and St. Petersburg history was unavailable because of a Mimir store-consistency block. |
| `BhaiyaSSHSessionTerminationErrors` | **Cannot fire for #661** | The live public-path drops exposed `cause="client"` and `reason="connection_closed"`. The rule requires transport/error signals, so its predicate was false and its timer never started. |
| `BhaiyaSSHUnexpectedDisconnect` | **Cannot fire for #661** | The legacy rule likewise requires `bhaiya_ssh_session_disconnects_total{cause="transport"}` or terminal/error reasons. The same live drops had no transport increase, so this predicate was also false. |

The SSH result is a real coverage blind spot, not a missing metric name. Bhaiya
SSH metrics exist in Ottawa; the issue is that the current raw termination
telemetry does not classify an abortive public-path reset.

## Stopped-delivery replay: Woodpecker #797

The push-to-main outage was also a coverage blind spot, but the precise claim
is **zero direct delivery-path coverage**, not literally zero related signal.
Pipeline 3237 (#799) succeeded at 06:26 UTC. Pipeline 3240 (#797) entered
Woodpecker `error` at 06:40 UTC with `event=push` and no workflows or steps;
the missing `woodpecker_ci_token` was therefore a scheduler/admission error
before any step-level failure could be exported. Every observed push pipeline
after that also entered `error`, while pull-request pipelines continued to
pass. Pipeline 3303 later succeeded after #825, but that recovery does not
change what could have detected the outage.

The all-tenant Mimir sweep found:

- no Woodpecker, CI, or pipeline alert rule;
- no Woodpecker/CI exporter, ServiceMonitor, public metrics series, or
  `woodpecker_pipeline_status`/`ci_pipeline_status` series in Ottawa,
  Robbinsdale, or St. Petersburg; and
- no `bhaiya_workspace_image_release_status` series during the incident
  window. That observer's series first appeared in Ottawa after recovery,
  around 11:24 UTC, and no corresponding ruler alert exists yet.

### Currency did not mean “last successful deploy”

`bhaiya_deployment_currency_status` is not a last-successful-deploy gauge. The
implementation compares the running binary's immutable source SHA with
Forgejo's effective `main` SHA, skipping the bounded set of bookkeeping
commits. The deployed binary can therefore equal the last successful release
and still be reported `behind` when `main` advances.

In the incident window, Ottawa had two `status="behind"` series at 05:30,
05:51, 06:26, and 06:40 UTC. `BhaiyaDeploymentCurrencyStale` had an active
timer beginning at 05:51:44 UTC and a 75-minute hold, so it was an older
source/deployed divergence that would have become firing around 07:06—not a
new transition caused by the first failed push at 06:40. It could have told an
operator that the control plane was stale, but it could not identify or time
the stopped Woodpecker path. If the baseline had been current before the
outage, this broad guard could eventually have noticed main moving ahead; it
is not a direct pipeline-status detector.

The same rule is loaded in all three tenants, but only Ottawa has Bhaiya
currency samples. Robbinsdale and St. Petersburg had no
`bhaiya_deployment_currency_status` series and no firing currency alert.

### Workspace-image and Flux signals

`BhaiyaWorkspaceImageAdoptionStale` was a delayed downstream signal in
Ottawa. At 06:40 the queued image was `0.3.295`, published and matching the
template; by 08:11 the queued `0.3.296` was missing and unknown. Its 75-minute
hold made it actionable around 09:27, long after the pipeline admission error,
and it says nothing about ordinary main pushes that do not affect the
workspace image. `BhaiyaWorkspaceImagePublicationStale` did not represent the
initial failure because its intended version still had a published registry
probe.

Flux was silent for the affected Ottawa path: `kubernetes-apps` was
`ReconciliationSucceeded` at both 06:26 and 06:40. St. Petersburg was also
ready. Robbinsdale had unrelated Garage dependency churn (`Unknown` /
`Progressing`) at those samples, not a Woodpecker delivery symptom, and the
`FluxKustomizationNotReady` predicate only matches `ready="False"` anyway.
Flux cannot observe a push workflow that fails before a new Git revision
reaches it.

The honest fleet-level conclusion is therefore: **no alert would have directly
detected “push-to-main pipelines are failing before execution.”** The fleet
had a broad, already-stale currency warning in Ottawa and a later
workspace-image consequence, but zero discriminating coverage for a stopped
delivery path. The incident was found by manually checking Woodpecker. This is
the same failure pattern as the SSH pair above: an apparently relevant signal
exists, but its predicate does not represent the incident that operators need
to catch.

## End-state snapshot — 2026-09-08 11:48 UTC

A fresh Mimir sweep across all three tenants found 24 firing instances, or 21
after excluding one `Watchdog` per tenant. That is below the fleet's earlier
mid-30s count. The per-tenant baseline was:

| Tenant | Firing instances | Excluding `Watchdog` | What was firing |
| --- | ---: | ---: | --- |
| Ottawa | 8 | 7 | `ProbeFailed` (JetKVM); `FluxKustomizationNotReady` (`kopiur-velero-home-restore-proof-target`); `KubeAPIErrorsHigh` (APPLY restores); `VeleroScheduleLatestBackupHasWarnings` (`media-config-backup`); `VeleroScheduleLatestBackupMissingVolumes` (`hermes-backup`, `bhaiya-tailscale-engineering`); `VeleroScheduleVolumeCoverageRegressed` (`bhaiya-backup`); `Watchdog` |
| Robbinsdale | 10 | 9 | `SmartDeviceHighTemperature`; `SmartDeviceTestFailed` (3 instances); `VeleroBackupStale` (`media-config-backup`); `VeleroPodVolumeBackupFailed` (`kometa-29814120-jdtzq/config`); `VeleroScheduleLastBackupFailed` (`media-config-backup`); `VeleroScheduleLatestBackupHasWarnings` (`media-config-backup`); `VeleroScheduleVolumeCoverageRegressed` (`home-backup`); `Watchdog` |
| St. Petersburg | 6 | 5 | `NodeHighMemoryUsage` (`192.168.73.248`); `NodeSchedulableMemoryHeadroomLow` (`orin-0`); `StPetersburgSparkMemoryAvailableLow` (`192.168.73.206`); `VeleroScheduleLatestBackupHasWarnings` (`home-assistant-backup`); `VeleroScheduleLatestBackupMissingVolumes` (`home-assistant-backup`); `Watchdog` |

No newly added alert was firing on healthy state. The new
`StPetersburgSparkMemoryAvailableLow` instance is a true positive: about 3.0
GiB is available out of 128.5 GiB, inside its intended 2–8 GiB warning band.
The new `BhaiyaWorkspaceServiceNoReadyEndpoints` alert was not firing and had
neither `not-ready` nor `missing` series; that is currently an observability
gap because the collector could not read `discovery/v1` EndpointSlices. #830
fixes the scheme and is in CI, so this alert needs a follow-up once real
endpoint data begins to populate. No rollback or Woodpecker alert was firing.
The St. Petersburg `NodeHighMemoryUsage` condition was also genuine at about
93% use, not a newly introduced false positive.

The known accumulator remained live: both Ottawa
`VeleroScheduleLatestBackupMissingVolumes` instances were still active from
2026-09-07 23:58 UTC for the same deleted-schedule Backup records
(`hermes-backup-20260907070001` and
`bhaiya-tailscale-engineering-20260907020000`). Its fix is still queued in
cos-hostclaims' batched rules PR, gated on #830 and endpoint-series
population. This is queued work, not a cleared signal.

## Implemented: detect an incomplete successful rule sync

The loader's two existing alerts cover a failed Job and a loader that has gone
stale. They do not cover the more deceptive case from km#2809: the loader Job
completes successfully, but a declared rule file or group is omitted from the
sync, so the ruler is healthy while the intended alert is absent. This is a
failure that produces success.

The detector is now a dedicated monitoring Deployment outside the Mimir loader
Kustomization. For each tenant it compares the expected `file/namespace` plus
group-name set in `expected-groups.tsv` with the live Mimir ruler API. A
declared group missing from the ruler is the km#2809 signature. Missing groups
are sent directly to Alertmanager as `MimirRuleGroupIncomplete`; group names
remain annotation data, not unbounded labels. Ruler API failures have a
separate `MimirRuleCompletenessCheckerFailed` alert.

The expected set is intentionally independent from the loader's
`mimir-rules.files` list. `tools/check-mimir-rules.sh` verifies it against every
rule source on disk, so a file omitted from the loader still remains expected
at runtime. The checker queries all three tenant IDs and does not alert on
extra live groups, which can be an intentional branch/live-version difference.

The bootstrap boundary is explicit: the checker is delivered by the Ottawa
monitoring app, not as a Mimir rule or loader container, and it posts directly
to Alertmanager. Its own presence therefore does not depend on the rule group
whose completeness it checks.

### km#2809 replay and timing

The committed replay constructs a successful ruler response containing every
declared group except `bhaiya-workspace-image/bhaiya-workspace-image.rules`.
The same parser and set comparison used by the checker reports that group as
missing and would fire `MimirRuleGroupIncomplete`; the test passes. A read-only
live run found no missing expected groups in any tenant. It did initially log
`stpetersburg-memory` as an extra because the live ruler had received that
group before the rule source was present on this branch; the current source
and expected set now include it.

`MISSING_GROUP_GRACE_SECONDS=300` is **5 minutes**. There is no downstream
Mimir `for:` because the checker posts directly to Alertmanager: `for=0m`.
With the 60-second poll interval, detection is 5–6 minutes after the omission;
Alertmanager's configured 1-minute `group_wait` makes worst-case notification
delay 7 minutes. That is the real end-to-end number next to the constant, not
an unstated grace-plus-`for` total like #807's 15m + 10m = 25m.

## The #808 dependency

Do **not** repair the SSH rules by matching `client_close` or
`reason="connection_closed"` directly. A normal clean user disconnect produces
the same raw close class. Such a widened rule would alert on ordinary session
ends and become noise immediately.

The safe predicate already identified during #661 is classified, not raw:

```text
termination_reason = client_close
AND transport_close_source = read_eof
AND gateway_to_client_bytes >= 500,000
AND since_last_gateway_byte_ms <= 100
```

It must be emitted once per transport, with trusted route attribution and a
bounded metric label set. The required classified counter does not exist today.
That makes corp/bhaiya **#808**—trusted Envoy-to-bhaiya connection identity and
route propagation—the prerequisite for these SSH alerts to detect #661 at all,
not merely an observability convenience. #808 supplies the join and trusted
route boundary needed to emit the classification honestly; only then should a
Mimir predicate be built around it. Tailscale remains a known workaround, not
the proposed solution to the public-path failure.

## Verification notes

- Pinned Prometheus 3.14.0 passed the Mimir PromQL and rule-loader checks.
- The existing rule-test runner passed; `job_failures_test.yaml` also passes
  when invoked directly but is not included by that runner.
- No rule, loader, namespace, or kustomization files were modified for this
  audit.

References: corp/bhaiya #808 (instrumentation prerequisite) and #661 (live
public-path failure).
