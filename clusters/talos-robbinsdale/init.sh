kubectl create ns monitoring
kubectl create ns 1password
kubectl create ns argocd
kustomize build clusters/talos-robbinsdale/apps/1password --enable-helm | kubectl apply --server-side -f - || true
kustomize build clusters/talos-robbinsdale/apps/monitoring --enable-helm | kubectl apply --server-side -f - || true
kustomize build clusters/talos-robbinsdale/apps/cilium --enable-helm | kubectl apply --server-side -f - 
kustomize build clusters/talos-robbinsdale/apps/argo-cd --enable-helm | kubectl apply --server-side -f - 
kubectl apply -f clusters/talos-robbinsdale/apps/argo-cd/apps/argo-cd.yaml
kubectl apply -f clusters/talos-robbinsdale/configs/localredirects.yaml