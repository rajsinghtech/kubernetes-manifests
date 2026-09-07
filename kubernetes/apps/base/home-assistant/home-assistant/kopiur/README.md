# StP Home Assistant — kopiur (Direct)

Narrow protect for `homeassistant-config` (local-path → hostPath on orin-0).

Constraints (also comments on the CRs):

1. `copyMethod: Direct` explicit (default Snapshot fails hostPath).
2. Source mount `readOnly: true` (never live-chgrp the only copy).
3. Dedicated Garage bucket `kopiur-stpetersburg` + own Kopia password (not Velero).
4. `Repository.spec.maintenance.enabled: false` (Garage degraded `_maintenance` RAW / km#2767).
5. Chart `0.10.7` + controller/webhook/mover digests pinned.
6. StP only — OT/RB HA already have Velero PVBs.

## Password escrow

`kopia-password.sops.yaml` is the recovery copy of the repository password.
It is encrypted in Git with the repository SOPS PGP key and deliberately keeps
the existing password, because rotating it would make the current Kopia
history unreadable. This is only an escrow if the corresponding private key is
held outside St Petersburg (and outside the cluster); the Flux `sops-gpg`
Secret is not an independent copy.

The Git copy trades cluster-loss survivability for repository access to the
encrypted secret: anyone who can decrypt the SOPS file can read the Kopia
password. Keep GitHub access and the PGP private-key backup restricted, and
verify the key can decrypt this file during disaster-recovery review.

Root mover (`runAsUser: 0` + `privilegedMode: true`) and Namespace
`privileged-movers` annotation: live `/config` has root-owned `0600` files;
mount stays read-only. `inheritSecurityContextFrom` is unusable — HA pins no
`runAsUser` in the pod spec (image USER only → InheritPinnedNoUid / empty tree).

**Scheduling:** `SnapshotPolicy.spec.mover` has **no** `tolerations` field
(schema reject). Direct movers reach tainted orin-0 via
`Repository.moverDefaults.sourceColocation: Auto` (default): pin to the RWO
holder node and **union the holder pod's tolerations** (HA already tolerates
`node-role.kubernetes.io/control-plane`). Explicit
`moverDefaults.tolerations` is belt-and-suspenders. HelmRelease root
`tolerations` only affect the **controller** Deployment, not mover Jobs.

**Acceptance (not “schedule exists”):** a `Snapshot` reaches Succeeded with
non-zero files, then a `Restore` into a **new empty PVC** byte-compares to
source. Leave the Velero `home-assistant-backup` schedule alone (km#2764).
