# Contributing to Kubernetes Manifests Repository

This document provides guidelines for contributing to this GitOps repository which manages multiple Kubernetes clusters using ArgoCD, Kustomize, and Helm.

## Repository Structure

This repository follows a GitOps approach where the desired state of Kubernetes clusters is declared in this repository, and ArgoCD automatically synchronizes the actual cluster state to match.

### Directory Layout

```
├── clusters/                    # Cluster-specific configurations
│   ├── common/                  # Shared configurations across clusters
│   │   ├── apps/               # Common applications
│   │   ├── bootstrap/          # Initial cluster setup
│   │   └── flux/               # Flux/GitOps configuration
│   ├── kind-stpetersburg/      # Kind cluster configuration
│   ├── talos-ottawa/           # Ottawa Talos cluster
│   └── talos-robbinsdale/      # Robbinsdale Talos cluster
├── infrastructure.drawio        # Infrastructure diagram
├── Makefile                    # Build and validation tools
└── requirements.txt            # Python dependencies
```

### Cluster-Specific Structure

Each cluster directory follows this pattern:

```
cluster-name/
├── apps/                       # Application deployments
│   └── app-name/
│       ├── app/               # Application manifests
│       ├── ks.yaml            # Kustomization source
│       ├── kustomization.yaml # Kustomize configuration
│       └── namespace.yaml     # Namespace definition
├── flux/                      # Flux configuration
└── talos/                     # Talos-specific configs (if applicable)
```

## Development Workflow

### 1. Making Changes

1. **Create a feature branch** from `main`:
   ```bash
   git checkout -b feature/your-change-description
   ```

2. **Make your changes** following the established patterns

3. **Validate your changes** using the provided Makefile:
   ```bash
   make validate-kustomize
   ```

4. **Test locally** if possible before committing

### 2. Application Structure Standards

When adding new applications, follow these conventions:

#### Required Files
- `namespace.yaml` - Define the application namespace
- `kustomization.yaml` - Kustomize configuration
- `ks.yaml` - Kustomization source for FluxCD
- Application manifests in `app/` subdirectory

#### Naming Conventions
- Use lowercase with hyphens for directory names
- Match namespace names to directory names where possible
- Use descriptive, consistent naming across similar resources

#### Resource Organization
- Group related resources in the same directory
- Use separate files for different resource types
- Include monitoring and security configurations where applicable

### 3. Configuration Management

#### Helm Charts
- Use official charts when available
- Pin chart versions in `helmrelease.yaml` files
- Store custom values in separate `values.yaml` files
- Document any custom configurations

#### Kustomize
- Use kustomization overlays for environment-specific changes
- Keep base configurations generic and reusable
- Use patches sparingly and document their purpose

#### Secrets Management
- Never commit plain-text secrets
- Use SOPS for encrypted secrets (`.sops.yaml` files)
- Reference secrets through proper Kubernetes secret objects

### 4. Validation and Testing

#### Pre-commit Requirements
- All Kustomize builds must pass validation
- YAML files must be properly formatted
- No plain-text secrets in commits
- Commit messages should be descriptive

#### Validation Commands
```bash
# Validate all kustomize builds
make validate-kustomize

# Check individual applications
kustomize build clusters/cluster-name/apps/app-name
```

## Application Categories

### Infrastructure Services
- **Monitoring**: Prometheus, Grafana, Hubble UI
- **Storage**: Ceph, MinIO, CSI drivers
- **Networking**: Cilium, Envoy Gateway, Cert-Manager
- **GitOps**: ArgoCD, Flux

### Applications
- **Media**: Jellyfin, Sonarr, Radarr, Frigate
- **Home Automation**: Home Assistant, Pi-hole
- **Development**: Code Server, Ollama, OpenWebUI
- **Utilities**: Gatus, OpenCost, Speedtest

## Best Practices

### Security
- Follow principle of least privilege for RBAC
- Use network policies where appropriate
- Regularly update container images
- Scan for vulnerabilities

### Resource Management
- Set appropriate resource requests and limits
- Use horizontal pod autoscaling where beneficial
- Implement proper health checks
- Configure persistent storage appropriately

### Monitoring and Observability
- Include ServiceMonitor for Prometheus scraping
- Add appropriate labels for service discovery
- Configure alerting for critical services
- Use consistent logging practices

### Documentation
- Update README.md when adding public services
- Document any custom configurations
- Include troubleshooting information
- Maintain infrastructure diagrams

## Common Patterns

### Adding a New Application

1. Create application directory structure:
   ```bash
   mkdir -p clusters/target-cluster/apps/app-name/{app,config}
   ```

2. Create required files:
   - `namespace.yaml`
   - `kustomization.yaml`
   - `ks.yaml`
   - Application manifests in `app/`

3. Add to cluster apps kustomization:
   ```yaml
   # clusters/target-cluster/flux/apps.yaml
   spec:
     path: ./clusters/target-cluster/apps/app-name
   ```

4. Validate and test:
   ```bash
   make validate-kustomize
   ```

### Updating Dependencies

1. Update chart versions in `helmrelease.yaml`
2. Review and update custom values
3. Test in development environment first
4. Validate with kustomize build
5. Monitor deployment after merge

## Getting Help

- Check existing applications for patterns and examples
- Review ArgoCD dashboard for deployment status
- Consult cluster-specific documentation in cluster directories
- Use the Makefile for validation and common tasks

## Code Review Guidelines

### For Reviewers
- Verify all validations pass
- Check for security best practices
- Ensure consistency with existing patterns
- Review resource allocations
- Validate documentation updates

### For Contributors
- Test changes locally when possible
- Include context in pull request descriptions
- Update documentation as needed
- Follow established naming conventions
- Run validation before submitting

## Emergency Procedures

### Rolling Back Changes
1. Identify the problematic commit
2. Create a revert commit
3. Push to trigger immediate sync
4. Monitor cluster status in ArgoCD

### Cluster Recovery
1. Check ArgoCD application status
2. Verify cluster connectivity
3. Review resource quotas and limits
4. Check for conflicting configurations

This repository serves multiple production clusters - always prioritize stability and follow the established patterns when making changes.