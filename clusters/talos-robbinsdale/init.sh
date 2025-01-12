kubectl create ns monitoring
kubectl create ns 1password
kubectl create ns argocd

kustomize build clusters/talos-robbinsdale/apps/monitoring --enable-helm | kubectl apply --server-side -f - || true
kustomize build clusters/talos-robbinsdale/apps/cilium --enable-helm | kubectl apply --server-side -f - 
cilium status --wait
kubectl apply -f clusters/talos-robbinsdale/configs/localredirects.yaml
kustomize build clusters/talos-robbinsdale/apps/argo-cd --enable-helm | kubectl apply --server-side -f - 
kubectl apply -f clusters/talos-robbinsdale/apps/argo-cd/apps/argo-cd.yaml
kustomize build clusters/talos-robbinsdale/apps/1password --enable-helm | kubectl apply --server-side -f - || true
open "https://start.1password.com/open/i?a=IDFR3VM7VNC2XCMUGMW3HC377I&v=gri6pniqnwoqzyegmgv6hflcuy&i=eu7ouubv742a77667lzuvjncxy&h=my.1password.com"