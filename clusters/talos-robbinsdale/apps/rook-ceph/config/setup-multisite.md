# Ceph Object Multisite Setup Instructions

## Deployment Order

1. **Deploy Primary Cluster (talos-ottawa) first:**
   ```bash
   # Apply the configuration to ottawa cluster
   kubectl apply -k clusters/talos-ottawa/apps/rook-ceph/config/
   ```

2. **Wait for primary cluster to be ready:**
   ```bash
   # Check that all components are running
   kubectl get pods -n rook-ceph
   kubectl get cephobjectrealm,cephobjectzonegroup,cephobjectzone,cephobjectstore -n rook-ceph
   ```

3. **Extract system user keys from primary cluster:**
   ```bash
   # Get the system user credentials created automatically
   kubectl get secret -n rook-ceph | grep system-user
   
   # Extract access and secret keys (replace with actual secret name)
   kubectl get secret rook-ceph-object-user-multisite-realm-system-user -n rook-ceph -o jsonpath='{.data.AccessKey}' | base64 -d
   kubectl get secret rook-ceph-object-user-multisite-realm-system-user -n rook-ceph -o jsonpath='{.data.SecretKey}' | base64 -d
   ```

4. **Update the secondary cluster secret:**
   ```bash
   # Edit the secret file with the actual base64 encoded values
   # clusters/talos-robbinsdale/apps/rook-ceph/config/multisite-keys-secret.yaml
   
   # Base64 encode the keys:
   echo -n "ACCESS_KEY_VALUE" | base64
   echo -n "SECRET_KEY_VALUE" | base64
   ```

5. **Deploy Secondary Cluster (talos-robbinsdale):**
   ```bash
   # Apply the configuration to robbinsdale cluster
   kubectl apply -k clusters/talos-robbinsdale/apps/rook-ceph/config/
   ```

## Verification

```bash
# On both clusters, verify the multisite configuration
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- radosgw-admin realm list
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- radosgw-admin zonegroup list
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- radosgw-admin zone list
```

## Networking Requirements

- The secondary cluster needs network access to the primary cluster's RGW endpoint
- Update the endpoint in `multisite-realm.yaml` if using different networking setup
- For cross-cluster communication, consider using service mesh or ingress controllers

## Configuration Summary

- **Primary Cluster (Ottawa):** Master zone in master zone group
- **Secondary Cluster (Robbinsdale):** Secondary zone in same zone group
- **Realm:** `multisite-realm` (shared across both clusters)
- **Zone Group:** `ottawa-zonegroup` (master zone group)
- **Zones:** `ottawa-zone` (master), `robbinsdale-zone` (secondary)