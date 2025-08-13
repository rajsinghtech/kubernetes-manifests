# OSD Recovery Procedure

## When OSD Shows Corrupted BlueStore Labels

### Error: `not all labels read properly, 5!=3` or `5!=4`

## Commands Sequence

```bash
# 1. Install ceph-volume in debug pod (if using Alpine)
kubectl exec -n kube-system <thunderbolt-debug-pod> -c debug -- apk add --no-cache ceph19-volume

# 2. Wipe disk with ceph-volume (for raw mode OSDs)
kubectl exec -n kube-system <thunderbolt-debug-pod> -c debug -- ceph-volume raw zap /dev/nvme0n1

# 3. Remove OSD from Ceph cluster
kubectl exec -n rook-ceph <toolbox-pod> -- bash -c "ceph osd out <osd-id> && ceph osd down <osd-id> && ceph osd purge <osd-id> --yes-i-really-mean-it"

# 4. Delete OSD deployment
kubectl delete deployment -n rook-ceph rook-ceph-osd-<osd-id>

# 5. Force delete OSD pods if stuck
kubectl delete pod -n rook-ceph -l ceph-osd-id=<osd-id> --force --grace-period=0

# 6. Remove OSD auth if still exists
kubectl exec -n rook-ceph <toolbox-pod> -- bash -c "ceph auth del osd.<osd-id>"

# 7. Delete all prepare jobs
kubectl delete job -n rook-ceph --all

# 8. Restart operator to trigger OSD recreation
kubectl -n rook-ceph delete pod -l app=rook-ceph-operator

# 9. Monitor recreation
kubectl get pods -n rook-ceph -w | grep osd
```

## Required Tools in Debug Pod

```bash
# Install if not present
apk add --no-cache sgdisk
```