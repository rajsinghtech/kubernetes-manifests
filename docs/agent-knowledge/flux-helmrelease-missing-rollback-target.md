# Flux HelmRelease: recover a stalled missing rollback target

Date: 2026-09-09 UTC

## Symptom

`FluxHelmReleaseNotReady` can remain critical for a HelmRelease whose workload
is already healthy. The Ottawa `flux-system/flux-operator` release is the
reference case:

- `Deployment/flux-operator` is Ready on the desired image;
- the Flux Kustomizations are Ready; but
- the HelmRelease is `Stalled=True` with reason `MissingRollbackTarget` and
  `upgradeFailures=2`.

Re-check the object before acting. In the reference incident, the counters
remained at `failures=2` and `upgradeFailures=2`, `Stalled` last changed at
06:29:57 UTC, and the helm-controller had no later `flux-operator` attempt or
HelmRelease event. That is a given-up release, not a retry loop.

This is a delivery-controller failure, not proof that the Deployment is down.
While it remains stalled, a later flux-operator upgrade can be withheld, so
the alert still needs an owner.

## Why a plain reconcile is not enough

Helm-controller's remediation path treats `MissingRollbackTarget` as a failed
upgrade with no usable rollback target. A plain reconcile preserves the failure
state and re-enters that rollback remediation; it does not clear the recorded
failure budget. The exact controller behavior was confirmed from the
controller source before documenting this procedure.

Do not repeatedly retry a plain reconcile and call that recovery. Do not delete
the HelmRelease or edit its status.

## Approved one-off recovery

After the owner confirms that the Deployment is healthy and the release should
be retried, run the following live action once:

```sh
flux reconcile helmrelease flux-operator -n flux-system --reset
```

`--reset` is a state-changing operation. It resets the failed remediation state
so Helm-controller can evaluate the current desired revision again; it is not a
manifest change and is not a substitute for fixing a bad chart or values file.
It is a normal retry, not `--force`, and it does not create the missing
successful Helm history target.

The reset first clears the failure counters, so the controller attempts the
current chart and values again. If that upgrade succeeds, the successful
release becomes a rollback target and the HelmRelease recovers. If the upgrade
fails again, the next reconciliation can enter rollback remediation and hit the
same missing-target condition again. The reset is therefore not guaranteed to
clear the alert; on that path, stop and investigate the new failed attempt
instead of repeatedly resetting it. The original failure occurred during the
Multus sandbox outage, so the now-healthy Deployment makes success plausible,
but does not guarantee it.

Do not run it unattended during another control-plane or CNI incident.

## Verification and escalation

Before the reset, record the HelmRelease conditions, failure counts, desired
chart revision, and Deployment image. After the reset, verify read-only that:

1. the HelmRelease returns to `Ready=True` and `Stalled` is no longer `True`;
2. `Released=True` and both failure counters return to zero after successful
   reconciliation;
3. the Deployment remains Available and its image is unchanged from the
   intended revision; and
4. `FluxHelmReleaseNotReady` clears and no dependent Flux Kustomization or
   HelmRelease becomes unhealthy.

The `Stalled` condition is normally removed rather than retained as an
explicit `False`; any remaining `Stalled=True` means recovery did not finish.
The manual reconcile normally updates the status within seconds. Allow the
Helm action's five-minute timeout (the controller logged `timeout of 5m0s` for
this release) before declaring it failed; the alert should clear on the next
metrics evaluation after `Ready=True`.

If the reset fails again, stop retrying. Inspect the HelmRelease events and
controller logs, confirm whether `MissingRollbackTarget` returned, identify the
failed resource or missing history, and treat it as a new release failure. A
healthy Deployment does not make an arbitrary reset or force-reset safe.

This runbook is deliberately separate from the immutable-Secret rotation
procedure in issue `#2908`: both are Flux state hazards, but the Secret fix is
name-based rotation, while this HelmRelease case is an owner-approved,
one-off remediation reset.
