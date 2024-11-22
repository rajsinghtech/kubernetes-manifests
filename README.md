# kubernetes-manifests
- To manually apply on cluster;
  - `flux reconcile kustomization flux-system --with-source`
- To use 1Password to populate credentials you must first setup secret `1password-secret` to store keys `connect_credentials` and `operator_token`
  - ex:
    ```bash
    kubectl create secret generic 1password-secret \
    --namespace=1password \
    --from-literal=connect_credentials={connect_credentials} \
    --from-literal=operator_token={operator_token}
    ```