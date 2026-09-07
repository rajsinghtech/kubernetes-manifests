# StP Home Assistant — kopiur (Direct)

Narrow protect for `homeassistant-config` (local-path → hostPath on orin-0).

Constraints (also comments on the CRs):

1. `copyMethod: Direct` explicit (default Snapshot fails hostPath).
2. Source mount `readOnly: true` (never live-chgrp the only copy).
3. Dedicated Garage bucket `kopiur-stpetersburg` + own Kopia password (not Velero).
4. `Repository.spec.maintenance.enabled: false` (Garage degraded `_maintenance` RAW / km#2767).
5. Chart `0.10.7` + controller/webhook/mover digests pinned.
6. StP only — OT/RB HA already have Velero PVBs.

**Acceptance (not “schedule exists”):** a `Snapshot` reaches Succeeded with
non-zero files, then a `Restore` into a **new empty PVC** byte-compares to
source. Leave the Velero `home-assistant-backup` schedule alone (km#2764).
