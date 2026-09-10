# Renovate exclusions

This is the review ledger for the small set of dependencies that Renovate is
explicitly forbidden to update. An exclusion is a temporary engineering
constraint, not a maintenance policy: `tools/check-renovate-exclusions.sh`
requires every disabled rule to name a review date and to appear in this
ledger. An expired date fails the repository's offline self-tests.

## Current exclusions

| Rule and paths | Why Renovate is disabled | Exit condition | Review by |
| --- | --- | --- | --- |
| `.github/renovate.json` generated/vendor rule: `kubernetes/apps/base/agent-sandbox/agent-sandbox/app/raw-manifest.yaml`; `kubernetes/apps/base/node-feature-discovery/nfd-common/install/intel-nfd.yaml`; `kubernetes/apps/base/kube-system/cilium-*/app/descheduler-cronjob.yaml`; `kubernetes/apps/base/local-path-storage/local-path-storage-*/app/local-path-provisioner.yaml` | These are vendored or generated upstream bundles. A one-line image edit can leave the controller, CRDs, or companion manifests on a different upstream release. The Agent Sandbox controller is running `v0.5.4`; the compatible release line has reached `v0.5.6`, while `v1.0.1` is a separate major line. | Add a reproducible upstream-bundle regeneration command and a render/schema test for each bundle, then replace the broad exclusion with a manager that updates the source reference and regenerates the complete bundle. | 2026-10-10 |

The Agent Sandbox row is the Bhaiya/workspace-relevant item. It is currently a
legitimate hold, not a claim that `v0.5.4` is current. The next owner should
either return the bundle to Renovate with that generator/test or record a new,
dated decision before this date expires.
