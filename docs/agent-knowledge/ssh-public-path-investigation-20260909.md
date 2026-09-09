# Public-path SSH drops — investigation state (2026-09-09)

This is the current state of the public Bhaiya SSH investigation. It records
what the cluster-side evidence has eliminated and the one remaining test that
requires access to the UniFi gateway. It is not a claim that the UniFi device
has been proven faulty.

## Conclusion

The reset is downstream of Envoy. All 17 of 17 matched disconnects were
`RemoteReset` at Envoy: Envoy received the reset from its downstream peer and
closed its upstream side normally. Envoy is therefore a bystander at the
observed reset boundary, not the identified source.

The in-cluster stateful limits and transport theories listed below are
eliminated. The remaining public-path hypotheses are UniFi NAT/flow state and
hardware or flow offload. The UniFi API exposes no live flow telemetry, showed
no counter discontinuity at the failure times, and offers no per-rule offload
disable. A global offload toggle is the only available discriminator.

## Eliminated

| Candidate | Evidence | Result |
| --- | --- | --- |
| Envoy as the reset source | All 17/17 disconnects were `RemoteReset` downstream of Envoy, with the reset arriving from the next hop. | **Eliminated as the source.** Envoy remains part of the path, but its record places the RST downstream. |
| Node Linux conntrack capacity | The Ottawa node's conntrack capacity had headroom. | **Eliminated.** |
| Node Linux conntrack utilisation | `nf_conntrack_count` stayed low relative to `nf_conntrack_max`; drop and insert-failure counters did not increment, and kernel logs had no `nf_conntrack: table full, dropping packet`. | **Eliminated.** |
| Cilium conntrack capacity/utilisation | Cilium CT maps peaked at 26.3%, with reverse-NAT lower; utilisation was approximately 1% at and after the failure timestamps. | **Eliminated.** |
| Envoy connection limits | The observed drops did not coincide with an Envoy connection-limit condition. | **Eliminated.** |
| Keepalive or idle eviction | The keepalive/idle-eviction explanation was tested and refuted three times. It does not explain the active slow-drip failures. | **Eliminated.** |
| Fixed duration or byte boundary | Public-path failures have not shown a stable elapsed-time or accumulated-byte cutoff. Earlier matched durations ranged from 2:54 to 13:45; later identical-path trials on 2026-09-09 06:54–06:55 lasted 4s, 81s, and a full 179s survival. | **Eliminated as a simple fixed boundary.** No particular byte count is an established trigger. |
| Shared-port/protocol rule shape | Raj split port 22 into a single-protocol TCP forward. The issue persisted: 6 failures and 1 survival across 7 trials, including 0/4 controlled runs. | **Eliminated as the fix.** Changing the port-22 rule shape did not remove the fault. |
| SSH-specific handling | Public HTTPS 443 also fails during a long slow-drip flow, while the equivalent Tailscale path survives indefinitely. | **Eliminated.** The symptom crosses protocols and is specific to the public path, not SSH. |

The duration and byte result is important: a trial that happens to last longer
does not establish a timeout threshold. The observed variance is compatible
with state that is created, exhausted, or recovered in the public path, but it
does not identify which stateful device is responsible.

## Remaining hypotheses

Only these public-path explanations remain actionable:

1. UniFi NAT or flow state is being evicted, exhausted, or otherwise mishandled.
2. UniFi hardware/flow offload is mishandling an established flow.

The read-only UniFi API showed no counter discontinuity at a failure time. That
does not exonerate either hypothesis because it provides neither per-flow
telemetry nor historical state sufficient to attribute a reset. Further
cluster-side conntrack, Cilium, or Envoy checks will not distinguish them.

## Working reproduction

Use Raj's existing external slow-drip harness through the public path, for
example the long-lived public attach:

```text
herdr --remote ssh://raj-codes@bhaiya.keiretsu.top
```

Run it from outside the cluster through the same public SOCKS/UniFi path used
for the failing trials. Do not run it from inside the cluster or through a
hairpin: that changes the path and invalidates the comparison. Keep the
endpoint, slow-drip workload, and traffic rate unchanged; record UTC start and
end times, protocol, completion/reset outcome, and byte totals. The same path
must be capable of producing both a reset and a survival, as demonstrated by
the 4s, 81s, and 179s trials above. The equivalent public HTTPS 443 slow-drip
test is the cross-protocol control.

Two harness traps invalidated earlier runs:

1. The completion marker matched SSH's own command echo. Before counting a
   completion, filter lines matching:

   ```text
   ^debug|Started with|Sending command
   ```

2. A remote test dies with the `tailcat` session unless it is run
   synchronously. Do not background it and assume the session will keep it
   alive; `setsid` is not available on macOS. Invoke the remote test
   synchronously and wait for its actual result.

## UniFi offload A/B test

This is a maintenance-window test for Raj. It must be run from an external
client over the public path, never via an in-cluster hairpin.

1. Record the baseline before changing anything: the current global offload
   setting, one or more results from the SSH and HTTPS slow-drip reproductions,
   gateway CPU and memory, WAN/LAN throughput, and packet loss/latency. The
   gateway is already around 75% memory, so include resource measurements in
   the decision record.
2. Disable the UniFi gateway's **global hardware/flow offload** setting. Do not
   change the port-22 forward or any protocol rule. There is no per-rule
   offload switch.
3. Repeat the same external SSH and HTTPS slow-drip trials with the same
   endpoints and workload. Record the same timestamps, completion/reset result,
   byte totals, gateway resource use, throughput, latency, and packet loss.
4. Restore the original offload setting after the comparison if it is not
   being left disabled as an approved operational change. Record the setting
   and the before/after results together.

The cost is global: gigabit forwarding moves to the gateway CPU and a
network-wide throughput drop is expected while offload is disabled. This is
not a harmless per-rule experiment; schedule it with users informed and watch
CPU, memory, throughput, latency, and loss during the window.

Both outcomes are useful:

- If the public-path failures stop with offload disabled, hardware fast-path
  handling is implicated. That is a strong A/B result for the remaining
  hypothesis, though it does not by itself identify the exact offload table or
  flow-state defect.
- If the failures continue, hardware/flow offload is exonerated for this
  symptom. The public path then needs a different theory, principally UniFi
  NAT/state behaviour or an upstream/WAN path problem; do not keep repeating
  cluster-side conntrack tests.

## Current mitigation and ownership

For a working connection today, swap the SOCKS hop to the Tailscale IPv4
literal `100.76.8.70` while retaining the Bhaiya workspace authority used by
the mux. The Tailscale hop survives indefinitely in the observed comparison.
This is a workaround, not a repair: it requires tailnet access and leaves the
public path broken for other users. `corp/bhaiya #661` and `corp/bhaiya #343`
therefore remain open.

The next discriminating action is Raj's UniFi offload A/B test. No further
in-cluster candidate remains open on the evidence above.
