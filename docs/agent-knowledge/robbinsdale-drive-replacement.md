# Robbinsdale drive replacement and stone thermal runbook

This is a staffed procedure. Do not drain, reweight, destroy, purge, or remove
a Ceph OSD unattended. All commands below are examples for the Robbinsdale
cluster and must be rechecked against the live mapping immediately before use.

## Current reference state

The 2026-09-09 inspection found:

| Host device | Serial | Current role | Evidence |
|---|---|---|---|
| `tank/sda` | `P8GN563X` | no live OSD | SMART failure flag `0`; no OSD/device entry |
| `tank/sdb` | `P8GUX83P` | `osd.12` | 45 PGs, about 117 MiB |
| `tank/sdc` | `P8J7YNNP` | `osd.2` | 36 PGs, about 127 MiB |

At the same inspection, Ceph was `HEALTH_OK`, all 12 OSDs were up/in, all
114 PGs were `active+clean`, and no recovery or backfill was running. PG
`44.6` was acting on `[osd.6, osd.1, osd.9]`, hosted by tank, stone, and titan.
The seven previously identified `k=2,m=1` objects were in PG `48.0`, whose
acting set included `osd.12`; that is why `osd.2` and `osd.12` must not be
drained together.

The SMART evidence is real media degradation, not just a harmless prediction:
reallocated sectors were 1905/1959/1374 on sda/sdb/sdc, and pending sectors
were 736/160/808. Ceph being healthy is the reason to schedule a controlled
replacement, not evidence that the drives are safe indefinitely.

## Preflight

Run from the manifests repository. These are read-only checks and should take
about five minutes:

```sh
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg stat
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
```

Confirm the serial-to-OSD mapping has not changed. `sda` has no Ceph OSD and
requires no `ceph osd out` action; its physical replacement is still a host
maintenance task.

## One OSD at a time

Drain `osd.2` / `sdc` first because it has the larger pending-sector count:

```sh
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out 2
```

The command itself is quick. With only about 127 MiB on the OSD, movement is
normally minutes; allow roughly 15–30 minutes before investigating, but never
use elapsed time as the gate.

Before touching `osd.12`, run all of these again:

```sh
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg stat
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd safe-to-destroy 2
```

The hard gate is `HEALTH_OK`, every PG `active+clean`, no degraded, misplaced,
recovery, or backfill state, and a successful `safe-to-destroy 2` result. A
timer is not a substitute for this gate. Only after it passes should the
operator perform the physical replacement/removal of `sdc`.

After the replacement plan is ready, drain `osd.12` / `sdb`:

```sh
tools/kc.sh rb -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out 12
```

Repeat the same full recovery gate, using `ceph osd safe-to-destroy 12`, before
removing or replacing `sdb`. The data movement is about 117 MiB and normally
takes minutes, but the same 15–30 minute planning allowance and status gate
apply.

Do not issue `ceph osd destroy`, `ceph osd purge`, or a reweight command as a
shortcut. The live Rook setting
`removeOSDsIfOutAndSafeToRemove=true` can remove an OSD after it is out and
safe; the desired storage configuration does not automatically re-add these
drives. Coordinate the replacement and re-add through the storage/GitOps plan.

## Separate stone nvme0 risk

`stone/nvme0` is not a Ceph OSD. It is the host `/var` device. The current
Garage node-local member mounts:

```text
/var/local-path-provisioner/garage-node-local/robbinsdale-700/metadata
/var/local-path-provisioner/garage-node-local/robbinsdale-700/data
```

The stone Garage gateway uses an SMB PVC, not nvme0. `/var` also holds node
runtime state such as kubelet, containerd, logs, and host-mounted daemon state;
those are not Ceph-replicated data.

The current `nvme0` SMART health flag passes, but temperature is 74°C against a
65°C alert threshold. Treat cooling and host-local storage maintenance as a
separate work item; Ceph OSD drain reasoning does not protect it.

The live Garage layout has 12 storage nodes across Ottawa, Robbinsdale, and St.
Petersburg, layout version 196, maximum zone redundancy, and all nodes healthy.
It currently reports 23 buckets, 102,324 objects, and 908.6 GiB of object data;
stone is one of three Robbinsdale `local-700` members, not the sole Garage
copy. No Garage data was found whose only replica is on stone. Recheck the
layout and node health before any host maintenance rather than relying on this
snapshot.
