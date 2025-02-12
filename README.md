# GitOps Repository
Welcome to the GitOps repository for managing the `k8s-robbinsdale` Kubernetes cluster. This repository leverages [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) for continuous delivery, [Kustomize](https://kustomize.io/) for configuration management, and [Helm](https://helm.sh/) for deploying applications. The repository defines the desired state of various applications and infrastructure components within the cluster, ensuring consistency and ease of management.

## Overview
This repository serves as the single source of truth for the `k8s-robbinsdale` Kubernetes cluster configurations. By following GitOps principles, any changes committed to this repository are automatically synchronized to the cluster, ensuring that the actual state matches the desired state defined here.

# Infrastructure Components (Not all are publically accessible)

## Applications

- [Jellyfin](https://jellyfin.lukehouge.com): Streaming media server.
- [OpenCost](https://opencost.rajsingh.info): Kubernetes resource cost monitoring.
- [OpenWebUI](https://chat.rajsingh.info): AI model web interface.
- [Minecraft](https://mc.rajsingh.info): Minecraft server.
- [Typeo](https://typeo.io): Typing practice.

## Critical Services

- [Pi-hole](https://pihole.lukehouge.com/admin): Network-wide ad blocking.
- [Pi-hole Secondary](https://pihole-secondary.lukehouge.com/admin): Network-wide ad blocking.
- [Ceph](https://ceph.lukehouge.com): Object storage.

## Monitoring and Observability

- [Grafana](https://grafana.lukehouge.com): Dashboard and graph composer.
- [Prometheus](https://prometheus.lukehouge.com): Monitoring system and time series database.
- [Hubble UI](https://hubble.rajsingh.info): Kubernetes network observability.
- [Gatus](https://gatus.lukehouge.com): Health monitoring.

## Cluster Management

- [Argo CD](https://argocd.rajsingh.info): GitOps continuous delivery tool.
- [Code Server](https://code.rajsingh.info): VS Code running in the browser.

## Media Management

- [Sonarr](https://media.lukehouge.com/sonarr): TV show management.
- [Radarr](https://media.lukehouge.com/radarr): Movie management.
- [Prowlarr](https://media.lukehouge.com/prowlarr): Indexer manager.

## Home Automation

- [Home Assistant](https://homeassistant.lukehouge.com)
- [Frigate](https://frigate.lukehouge.com)