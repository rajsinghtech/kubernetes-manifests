# Kubernetes Monitoring Stack

This directory contains a complete monitoring stack for Kubernetes, managed by Flux CD.

## Components

### Prometheus Stack
- Prometheus for metrics collection and storage
- Grafana for dashboards and visualization
- AlertManager for alerting

### Logging
- Loki for log aggregation and querying
- Promtail for log collection from pods

### Tools
- Karma as an alternative UI for AlertManager

## Configuration

The monitoring stack uses CephFS for persistent storage and S3-compatible storage for Loki's logs.

## Dashboards

Pre-configured dashboards are included for:
- Kubernetes resource monitoring
- Tailscale networking
- ArgoCD deployment status
- Ceph storage metrics
- VolSync replication status

## Ingress

The stack is exposed via Kubernetes Gateway API using Envoy Gateway. 