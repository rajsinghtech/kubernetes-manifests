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
