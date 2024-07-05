# Bootstrap k8s cluster 
``` sh
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=latest INSTALL_K3S_EXEC='--flannel-backend=none --disable-network-policy --disable traefik --disable servicelb --disable-kube-proxy --token 12345' sh -

cilium install --helm-set operator.replicas=1 --helm-set k8sServiceHost=127.0.0.1 --helm-set k8sServicePort=6443 --helm-set bgpControlPlane.enabled=true
```

