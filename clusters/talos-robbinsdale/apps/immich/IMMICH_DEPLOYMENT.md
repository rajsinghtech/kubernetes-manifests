# Immich Deployment Documentation

## Overview

This document provides comprehensive documentation for the Immich deployment in the Kubernetes cluster. Immich is a self-hosted photo and video management solution that provides features similar to Google Photos.

## Architecture

The Immich deployment consists of several interconnected components working together to provide a complete photo and video management platform.

### Core Components

1. **Immich Application (Helm Chart v0.9.0)**
   - Main application running Immich v1.135.3
   - Consists of multiple services: server, microservices, machine learning
   - Deployed via Flux HelmRelease

2. **Database (PostgreSQL with CloudNative-PG)**
   - PostgreSQL 15 with vector extensions for AI features
   - Uses CloudNative Vectorchord image for enhanced vector capabilities
   - Single instance deployment with monitoring enabled

3. **Cache (Dragonfly Redis)**
   - High-performance Redis-compatible cache
   - 3-replica cluster for high availability
   - Configured with 1GB memory limit per instance

4. **Storage (Multi-tier)**
   - SMB volumes for photo/video storage and library data
   - S3-compatible backup for database
   - Ceph block storage for database persistence

5. **Networking (Gateway API)**
   - HTTPRoute configuration for web access
   - Multi-domain support (rajsingh.info and lukehouge.com)
   - Integration with Homer dashboard

## Component Details

### 1. Immich Application

**File:** `helmrelease.yaml`

- **Chart Version:** immich-0.9.0
- **Application Version:** v1.135.3
- **Update Interval:** 30 minutes
- **Remediation:** 3 retries on failure

**Key Configuration:**
- Metrics enabled for monitoring
- External persistence for photos and library
- Custom database and Redis connections
- Secrets managed via 1Password integration

### 2. PostgreSQL Database

**File:** `pg.yaml`

**Specifications:**
- **Image:** `ghcr.io/tensorchord/cloudnative-vectorchord:15-0.3.0`
- **Instances:** 1
- **Storage:** 8Gi on Ceph block storage
- **Extensions:** vchord, cube, earthdistance

**Features:**
- Vector search capabilities for AI-powered photo organization
- Automated S3 backups via Barman Cloud
- Daily backup schedule at 11 PM
- 30-day retention policy
- Pod monitoring enabled

**Database Configuration:**
- Database: `immich`
- Owner: `immich` (with SUPERUSER privileges)
- Data checksums enabled
- Required extensions automatically installed

### 3. Dragonfly Redis Cache

**File:** `redis.yaml`

**Specifications:**
- **Replicas:** 3
- **Memory:** 1000M per instance (1500M limit)
- **CPU:** 25m request per instance
- **Threads:** 2 proactor threads per instance

**Configuration:**
- Maximum memory: 1000MB per instance
- Lua scripting with undeclared keys allowed
- Password authentication via 1Password secret

### 4. Storage Configuration

**File:** `unas.yaml`

The deployment uses multiple storage tiers:

#### SMB Storage Volumes

**Photo Storage (`immich-unas-pics`):**
- **Capacity:** 2Ti
- **Access Mode:** ReadWriteMany
- **Source:** `//192.168.50.115/k8s/pics`
- **Usage:** Read-only access for existing photos

**Library Storage (`immich-unas`):**
- **Capacity:** 2Ti
- **Access Mode:** ReadWriteMany
- **Source:** `//192.168.50.115/k8s/immich`
- **Usage:** Read-write access for Immich library data

**SMB Configuration:**
- File mode: 0777
- Directory mode: 0777
- CSI driver: `smb.csi.k8s.io`
- Persistent volume reclaim policy: Retain

#### Database Storage
- **Type:** Ceph block storage
- **Class:** `ceph-block-replicated-nvme`
- **Size:** 8Gi
- **Usage:** PostgreSQL data persistence

### 5. Backup Strategy

The deployment implements a comprehensive backup strategy with dual S3 targets.

#### Database Backups

**Primary S3 (DigitalOcean Spaces):**
- **File:** `s3-backup.yaml`
- **Destination:** `s3://keiretsu/${LOCATION}/immich/postgres/`
- **Endpoint:** `https://nyc3.digitaloceanspaces.com`
- **Schedule:** Daily at 11 PM
- **Retention:** 30 days

**Secondary S3 (MinIO):**
- **File:** `s3-backup-minio.yaml`
- **Destination:** `s3://immich-postgres-backups/`
- **Endpoint:** `http://minio-hl.home.svc.cluster.local:9000`
- **Retention:** 30 days

#### Disaster Recovery

**File:** `pg-restore.yaml`

A separate PostgreSQL cluster configuration for disaster recovery:
- Can restore from S3 backups
- Uses the same image and configuration as the primary database
- References the primary cluster's backup location

### 6. Security & Secrets Management

**File:** `secret.yaml`

All sensitive data is managed through 1Password integration:

**Database Credentials:**
- **Secret:** `immich-postgres-user`
- **Path:** `vaults/K8s/items/immich-pg`
- **Contains:** username and password for PostgreSQL

**Redis Credentials:**
- **Secret:** `immich-dragonfly-secret`
- **Path:** `vaults/K8s/items/immich-dragonfly`
- **Contains:** password for Dragonfly Redis

**S3 Credentials:**
- Managed via cluster-level variables
- Separate credentials for DigitalOcean and MinIO

### 7. Network Access

**File:** `httproute.yaml`

**Configuration:**
- **Protocol:** HTTP/HTTPS
- **Domains:** 
  - `immich.rajsingh.info`
  - `immich.lukehouge.com`
- **Port:** 2283
- **Path:** `/` (all traffic)

**Gateway Integration:**
- Uses both Tailscale and public gateways
- Integrated with Homer dashboard for service discovery
- Automatic service categorization as "Media"

## Dependencies

### Required Operators and Systems

1. **CloudNative-PG (CNPG)**
   - PostgreSQL operator for database management
   - Required for PostgreSQL cluster creation and backup

2. **Dragonfly Operator**
   - Manages Dragonfly Redis instances
   - Handles clustering and authentication

3. **Volsync**
   - Volume synchronization and backup
   - Used for persistent volume management

4. **1Password Operator**
   - Secret management integration
   - Automatically syncs secrets from 1Password vaults

5. **Gateway API**
   - Network routing and ingress
   - Handles HTTPRoute configurations

6. **SMB CSI Driver**
   - Enables SMB volume mounting
   - Required for NAS storage integration

7. **Ceph Storage**
   - Block storage provider
   - Used for database persistence

### Flux Dependencies

The deployment is managed by Flux with the following dependencies:
- **Source:** Git repository `home-kubernetes`
- **Path:** `./clusters/${CLUSTER_NAME}/apps/immich/app`
- **Interval:** 30 minutes
- **Timeout:** 5 minutes

## Monitoring and Observability

### Database Monitoring
- PostgreSQL metrics via CNPG pod monitor
- Custom dashboards for database performance
- Backup status monitoring

### Application Metrics
- Immich metrics enabled in Helm configuration
- Integration with Prometheus stack
- Custom alerts for service availability

### Homer Dashboard Integration
- Automatic service discovery
- Categorized under "Media" services
- Custom icon and description
- Keyword tags for searching

## High Availability and Scaling

### Database
- Single instance (can be scaled to multiple replicas)
- Automated failover with CNPG
- Point-in-time recovery from S3 backups

### Redis Cache
- 3-replica cluster for high availability
- Automatic failover and clustering
- Memory-based persistence

### Application
- Horizontal scaling supported via Helm values
- Stateless microservices architecture
- Load balancing via Kubernetes services

## Maintenance and Operations

### Regular Tasks

1. **Monitor backup status:** Check S3 backup success daily
2. **Database maintenance:** CNPG handles automatic maintenance
3. **Storage monitoring:** Monitor SMB volume capacity
4. **Security updates:** Update Immich version regularly

### Troubleshooting

**Common Issues:**
1. **SMB mount failures:** Check NAS connectivity and credentials
2. **Database connection errors:** Verify PostgreSQL cluster status
3. **Redis connection issues:** Check Dragonfly cluster health
4. **Backup failures:** Verify S3 credentials and connectivity

**Useful Commands:**
```bash
# Check Immich pods
kubectl get pods -n immich

# Check database status
kubectl get clusters.postgresql.cnpg.io -n immich

# Check Dragonfly status
kubectl get dragonfly -n immich

# Check persistent volumes
kubectl get pv | grep immich

# Check HTTPRoute status
kubectl get httproute -n immich
```

## Configuration Variables

The deployment uses several environment variables defined in the cluster configuration:

- `${CLUSTER_NAME}`: Current cluster name (talos-robbinsdale)
- `${LOCATION}`: Geographic location for backups
- `${COMMON_S3_ACCESS_KEY}`: S3 access key for DigitalOcean
- `${COMMON_S3_SECRET_KEY}`: S3 secret key for DigitalOcean
- `${MINIO_ACCESS_KEY}`: MinIO access key
- `${MINIO_SECRET_KEY}`: MinIO secret key

## Version Information

- **Immich Application:** v1.135.3
- **Helm Chart:** immich-0.9.0
- **PostgreSQL:** 15 with Vectorchord extensions
- **Dragonfly:** Latest (managed by operator)
- **Chart Repository:** https://immich-app.github.io/immich-charts

## Future Improvements

1. **Multi-cluster deployment:** Spread across multiple Kubernetes clusters
2. **Enhanced monitoring:** Custom Grafana dashboards
3. **Automated testing:** Health checks and automated validation
4. **Storage optimization:** Implement tiered storage for older photos
5. **Performance tuning:** Optimize database and cache configurations

---

*This documentation reflects the current state of the Immich deployment as of the latest commit. For the most up-to-date configuration, refer to the actual Kubernetes manifests in the repository.*