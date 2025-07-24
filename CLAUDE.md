# Claude Instructions for Kubernetes Manifests Repository

This file contains specific instructions for Claude AI to effectively work with this GitOps repository that manages multiple Kubernetes clusters.

## Repository Overview

**Purpose**: GitOps repository managing Kubernetes clusters using ArgoCD, Kustomize, and Helm  
**Clusters**: kind-stpetersburg, talos-ottawa, talos-robbinsdale  
**Primary Tools**: ArgoCD, Flux, Kustomize, Helm, SOPS  
**Validation**: Use `make validate-kustomize` to validate changes

## Core Principles

1. **GitOps First**: All cluster changes must be made via git commits to this repository
2. **Validation Required**: Always run `make validate-kustomize` before committing
3. **Security Conscious**: Never commit plain-text secrets, use SOPS encryption
4. **Pattern Consistency**: Follow existing patterns in the repository structure
5. **Documentation**: Update README.md when adding publicly accessible services

## Repository Structure Guide

### Cluster Organization
```
clusters/
├── common/                 # Shared configurations (Flux, apps, repositories)
├── kind-stpetersburg/     # Development/testing cluster
├── talos-ottawa/          # Production cluster in Ottawa
└── talos-robbinsdale/     # Primary production cluster
```

### Application Structure Pattern
```
apps/app-name/
├── app/                   # Application manifests (deployments, services, etc.)
├── config/               # Configuration files (optional)
├── ks.yaml              # Kustomization source for FluxCD
├── kustomization.yaml   # Kustomize configuration
└── namespace.yaml       # Namespace definition
```

## Common Tasks and Commands

### Validation and Testing
```bash
# Validate all kustomize configurations
make validate-kustomize

# Test specific application build
kustomize build clusters/talos-robbinsdale/apps/app-name --enable-helm

# Check dependencies are installed
make install-deps
```

### Adding New Applications

1. **Create directory structure**:
   ```bash
   mkdir -p clusters/TARGET_CLUSTER/apps/APP_NAME/{app,config}
   ```

2. **Required files**:
   - `namespace.yaml` - Define namespace
   - `kustomization.yaml` - Kustomize config
   - `ks.yaml` - FluxCD Kustomization source
   - Application manifests in `app/` directory

3. **Add to cluster apps list**:
   Edit `clusters/TARGET_CLUSTER/flux/apps.yaml` to include new app

4. **Validate**: Run `make validate-kustomize`

### Working with Helm Charts

- Use `helmrelease.yaml` files for Helm deployments
- Pin specific chart versions
- Store custom values in `values.yaml` files
- Reference Helm repositories in `clusters/common/flux/repositories/helm/`

### Secret Management

- **Never commit plain-text secrets**
- Use SOPS for secret encryption (files ending in `.sops.yaml`)
- Reference secrets via Kubernetes Secret objects
- Store encrypted cluster secrets in `clusters/CLUSTER/flux/vars/cluster-secrets.sops.yaml`

## Cluster-Specific Guidelines

### talos-robbinsdale (Primary Production)
- **Most comprehensive**: Contains majority of applications
- **High availability**: Critical services with redundancy
- **Resource-rich**: Largest resource allocations
- **External access**: Many services exposed via ingress

### talos-ottawa (Secondary Production)
- **Selective deployment**: Subset of applications
- **Cluster mesh**: Connected to robbinsdale via Cilium
- **Backup services**: Some services for redundancy

### kind-stpetersburg (Development)
- **Testing environment**: For validating changes
- **Minimal resources**: Limited resource allocations
- **Experimental**: Safe for testing new configurations

## Application Categories

### Infrastructure (clusters/common/apps/)
- **argocd**: GitOps continuous delivery
- **cert-manager**: Certificate management
- **monitoring**: Prometheus, Grafana stack
- **flux-system**: GitOps operator
- **tailscale**: VPN connectivity

### Cluster-Specific Applications

#### Networking & Security
- **cilium**: CNI and network security
- **envoy-gateway-system**: API gateway
- **ingress-nginx**: Ingress controller (robbinsdale only)

#### Storage
- **rook-ceph**: Distributed storage (robbinsdale)
- **minio-operator**: Object storage
- **local-path-storage**: Local storage provider

#### Monitoring & Observability
- **monitoring**: Prometheus + Grafana stack
- **hubble-ui**: Network observability
- **gatus**: Health monitoring (robbinsdale)
- **opencost**: Kubernetes cost monitoring

#### Applications
- **media**: Jellyfin, Sonarr, Radarr (robbinsdale)
- **home**: Home Assistant, Frigate, Code-Server (robbinsdale)
- **immich**: Photo management (robbinsdale)
- **ollama**: AI model hosting (robbinsdale)

## Best Practices for Claude

### When Making Changes

1. **Always validate first**: Use `make validate-kustomize`
2. **Follow patterns**: Look at existing applications for structure
3. **Check resources**: Ensure appropriate resource requests/limits
4. **Security review**: No secrets, proper RBAC, network policies
5. **Update documentation**: Add to README.md if publicly accessible

### Code Patterns to Follow

#### Namespace Creation
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app-name
  labels:
    name: app-name
```

#### Kustomization Source (ks.yaml)
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: app-name
  namespace: flux-system
spec:
  path: ./clusters/CLUSTER_NAME/apps/app-name
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

#### HelmRelease Pattern
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: app-name
  namespace: app-namespace
spec:
  interval: 30m
  chart:
    spec:
      chart: chart-name
      version: "x.y.z"
      sourceRef:
        kind: HelmRepository
        name: repository-name
        namespace: flux-system
  values:
    # Custom values here
```

### Resource Naming Conventions

- **Directories**: lowercase with hyphens (`my-app-name`)
- **Namespaces**: match directory names where possible
- **Labels**: consistent labeling for monitoring and selection
- **Services**: descriptive names matching function

### Troubleshooting Common Issues

#### Kustomize Build Failures
1. Check YAML syntax and indentation
2. Verify all referenced files exist
3. Ensure proper resource ordering
4. Check for circular dependencies

#### Secret Issues
1. Verify SOPS encryption is working
2. Check secret references in manifests
3. Ensure proper secret mounting in pods

#### Resource Conflicts
1. Check for duplicate resource names
2. Verify namespace isolation
3. Look for conflicting labels/selectors

## Monitoring and Maintenance

### Health Checks
- Monitor ArgoCD dashboard for sync status
- Check Grafana dashboards for cluster health
- Review Prometheus alerts for issues
- Use Gatus for service availability

### Regular Maintenance
- Update Helm chart versions regularly
- Review and update resource allocations
- Rotate secrets periodically
- Clean up unused resources

## External Dependencies

### Required Tools
- **kustomize**: YAML configuration management
- **helm**: Kubernetes package manager  
- **sops**: Secret encryption
- **kubectl**: Kubernetes CLI (for testing)

### Helm Repositories
Located in `clusters/common/flux/repositories/helm/`:
- bitnami, prometheus-community, grafana, jetstack, etc.
- Add new repositories here when needed

### Git Repositories  
Located in `clusters/common/flux/repositories/git/`:
- External git sources for applications
- Add new git sources here when needed

## Emergency Procedures

### Rollback Process
1. Identify problematic commit via ArgoCD
2. Create git revert commit
3. Push to trigger immediate sync
4. Monitor cluster recovery

### Validation Failures
1. Run `make validate-kustomize` to identify issues
2. Fix YAML syntax or missing references
3. Test individual component builds
4. Commit only after full validation passes

## Integration with External Services

### Tailscale Integration
- VPN connectivity for secure access
- Tailscale operator for Kubernetes integration
- Private service exposure via Tailscale subnet router

### Cloudflare Integration  
- DNS management via external-dns
- Tunnel connections for external access
- Certificate management integration

### Storage Backends
- **Ceph**: Primary distributed storage (robbinsdale)
- **MinIO**: Object storage with S3 compatibility
- **SMB/NFS**: External storage mounts

This repository represents critical infrastructure - always test changes thoroughly and follow established patterns when contributing.