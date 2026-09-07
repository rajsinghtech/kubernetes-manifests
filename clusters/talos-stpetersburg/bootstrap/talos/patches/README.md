# Talos Patches

This directory contains machine configuration patches for the St. Petersburg cluster.

## Directory Structure

```
patches/
├── global/       # Applied to all nodes
├── controller/   # Applied to control plane nodes only
└── node/         # Node-specific patches
```

## Global Patches (8 files)

Applied to every node in the cluster:

- `cluster-discovery.yaml` — Cluster discovery settings
- `disable-search-domain.yaml` — DNS search domain configuration
- `hostdns.yaml` — Host DNS settings
- `kubelet.yaml` — Kubelet configuration (max-pods, node IP)
- `local-path-provisioner.yaml` — Local storage mounts
- `machine-logging.yaml` — Machine log forwarding
- `metrics-server.yaml` — Metrics server deployment
- `sysctls.yaml` — Kernel sysctl tuning

## Controller Patches (5 files)

Applied to control plane nodes only:

- `api-access.yaml` — KubePrism and Talos API access
- `disable-proxy.yaml` — Disable kube-proxy (using Cilium)
- `etcd-metrics-patch.yaml` — Etcd/scheduler/controller-manager metrics
- `kubelet-certs.yaml` — Kubelet certificate approver
- `apiserver-resources.yaml` — kube-apiserver memory request (#700; apply via talosctl)

## Node Patches (3 files)

Node-specific overrides:

- `spark-0.yaml` — NVIDIA GB10 specific configuration
- `spark-1.yaml` — NVIDIA GB10 specific configuration
- `orin-0.yaml` — Jetson Orin specific configuration
