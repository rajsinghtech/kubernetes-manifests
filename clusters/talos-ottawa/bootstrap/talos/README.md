# Talos Kubernetes Cluster with Thunderbolt Networking

This setup uses `mise` and `talhelper` to manage a 3-node Talos Kubernetes cluster with high-speed Thunderbolt networking.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Complete Fresh Installation Workflow](#complete-fresh-installation-workflow)
- [Post-Installation](#post-installation)
- [Common Operations](#common-operations)
- [Troubleshooting](#troubleshooting)
- [Directory Structure](#directory-structure)

## Prerequisites

### Hardware Requirements

- 3 bare-metal nodes with:
  - 2x Thunderbolt ports per node
  - Multiple NVMe drives (using `/dev/nvme1n1` for Talos)
  - Network interfaces configured with static DHCP mappings
  - Thunderbolt cables connecting all nodes in a mesh topology

### Network Topology

```bash
ms01-1 (169.254.255.101) <--TB--> ms01-2 (169.254.255.102)
   |                                    |
   TB                                   TB
   |                                    |
   v                                    v
ms01-3 (169.254.255.103) <-----TB-------+
```

### Expected Network Configuration

- **ms01-1**:
  - Primary: 192.168.169.113 (Static DHCP on enp89s0)
  - Secondary: 192.168.249.113/24 (Static on enp2s0f0np0)
  - Thunderbolt: 169.254.255.101/32
- **ms01-2**:
  - Primary: 192.168.169.114 (Static DHCP on enp89s0)
  - Secondary: 192.168.249.114/24 (Static on enp2s0f0np0)
  - Thunderbolt: 169.254.255.102/32
- **ms01-3**:
  - Primary: 192.168.169.115 (Static DHCP on enp89s0)
  - Secondary: 192.168.249.115/24 (Static on enp2s0f0np0)
  - Thunderbolt: 169.254.255.103/32
- **VIP**: 192.168.169.25 (shared between control planes)

## Complete Fresh Installation Workflow

### Phase 1: Workstation Preparation

```bash
# 1. Navigate to cluster directory
cd /Users/kartik/workspace/kubernetes-manifests/clusters/talos-ottawa

# 2. Install required tools
brew install mise
mise install  # Installs: talhelper, talosctl, sops, age, kubectl, task

# 3. Setup SOPS with existing PGP key
# Copy existing SOPS configuration (we're using PGP, not Age)
cp ../common/.sops.yaml .

# Import your PGP private key (if you have a sops.asc file)
# IMPORTANT: Replace /path/to/sops.asc with your actual key location
gpg --import /path/to/sops.asc

# Verify the key was imported
gpg --list-secret-keys | grep -B2 FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5

# Trust the key (required for encryption)
echo "FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5:6:" | gpg --import-ownertrust

# Set GPG_TTY for terminal PIN entry (if needed)
export GPG_TTY=$(tty)

# Test that you can decrypt existing secrets (this is the real test)
cd /Users/kartik/workspace/kubernetes-manifests/clusters/talos-ottawa
sops -d flux/vars/cluster-secrets.sops.yaml > /dev/null && echo "✅ PGP key working" || echo "❌ Cannot decrypt - check PGP key"

# 4. Generate and encrypt Talos cluster secrets
# This is handled automatically by mise!
mise run init

# This command will:
# - Generate new Talos secrets
# - Automatically encrypt them with your PGP key (FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5)
# - Save to bootstrap/talos/talsecret.sops.yaml
# - Remove unencrypted temporary files

# Verify encryption worked
sops -d bootstrap/talos/talsecret.sops.yaml | head -5  # Should show decrypted content
```

### Phase 2: Create Installation Media

```bash
# 1. Download Talos ISO with required extensions
# This schematic includes: thunderbolt, intel-ucode, amd-ucode, util-linux-tools, zfs
SCHEMATIC_ID="ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
TALOS_VERSION="v1.9.3"  # Or check for newer version
curl -O "https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/metal-amd64.iso"

# 2. Create bootable USB (macOS)
diskutil list                          # Find your USB drive (e.g., disk4)
diskutil unmountDisk /dev/diskX        # Replace X with your disk number
sudo dd if=metal-amd64.iso of=/dev/rdiskX bs=1m status=progress
diskutil eject /dev/diskX

# Note: Use 'rdiskX' (raw disk) for faster writes on macOS
```

### Phase 3: Physical Setup & Installation

1. **Pre-Installation Checklist:**
   - [ ] Connect Thunderbolt cables between all nodes (full mesh)
   - [ ] Connect network cables
   - [ ] Ensure static DHCP mappings are configured for:
     - ms01-1: 192.168.169.113
     - ms01-2: 192.168.169.114
     - ms01-3: 192.168.169.115
   - [ ] Have IPMI/console access ready

2. **Install Talos on all 3 nodes:**
   - Boot each node from USB
   - Talos installer will auto-detect disks
   - Install to disk (typically auto-selects appropriate disk)
   - Remove USB and let node reboot
   - Node will boot into **maintenance mode**
   - Verify each node gets its expected IP via static DHCP

3. **Verify all nodes are in maintenance mode:**
```bash
# Should see all 3 nodes responding
for ip in 192.168.169.113 192.168.169.114 192.168.169.115; do
  echo -n "Node $ip: "
  talosctl -n $ip --insecure version | grep Tag || echo "❌ Not responding"
done
```

### Phase 4: Gather Hardware Information

**Critical: Do this for ALL nodes before generating configs**

```bash
# Create directory for hardware info
mkdir -p hardware-info
cd hardware-info

# Gather info from all nodes
echo "📡 Gathering hardware info from all nodes..."

# ms01-1
echo "Getting info from ms01-1..."
talosctl -n 192.168.169.113 --insecure get disks -o yaml > ms01-1-disks.yaml
talosctl -n 192.168.169.113 --insecure get links -o yaml > ms01-1-links.yaml

# ms01-2
echo "Getting info from ms01-2..."
talosctl -n 192.168.169.114 --insecure get disks -o yaml > ms01-2-disks.yaml
talosctl -n 192.168.169.114 --insecure get links -o yaml > ms01-2-links.yaml

# ms01-3
echo "Getting info from ms01-3..."
talosctl -n 192.168.169.115 --insecure get disks -o yaml > ms01-3-disks.yaml
talosctl -n 192.168.169.115 --insecure get links -o yaml > ms01-3-links.yaml

# Extract critical information
echo ""
echo "=== 🔍 NVMe Serial Numbers (for /dev/nvme1n1) ==="
for node in ms01-1 ms01-2 ms01-3; do
  echo -n "$node: "
  grep -A5 "device_name: /dev/nvme1n1" ${node}-disks.yaml | grep "serial:" | awk '{print $2}'
done

echo ""
echo "=== 🔍 Network Interfaces ==="
for node in ms01-1 ms01-2 ms01-3; do
  echo "$node:"
  grep "linkName:" ${node}-links.yaml | grep -v "lo" | awk '{print "  - " $2}'
done

echo ""
echo "=== 🔍 Thunderbolt Bus Paths (should see thunderbolt interfaces) ==="
grep -h "busPath:" *-links.yaml | sort -u

cd ..
```

### Phase 5: Update Configuration with Actual Hardware Info

```bash
# 1. Edit talconfig.yaml with the serial numbers you just gathered
vim bootstrap/talos/talconfig.yaml

# For each node, replace REPLACE_WITH_ACTUAL_SERIAL with the actual serial
# Example:
# nodes:
#   - hostname: "ms01-1"
#     installDiskSelector:
#       serial: "S4J4NF0NA12345X"  # <-- Put actual serial here

# 2. Verify network interface names match (should be enp89s0 and enp2s0f0np0)
# If different, update the interface names in talconfig.yaml

# 3. Save and exit
```

### Phase 6: Generate and Deploy Cluster

```bash
# 1. Initialize secrets (if not already done in Phase 1)
mise run init  # Creates and encrypts talsecret.sops.yaml if it doesn't exist

# 2. Generate all node configurations
echo "🔧 Generating Talos configurations..."
mise run genconfig

# 3. Verify generated configs exist
ls -la bootstrap/talos/clusterconfig/
# Should see: ms01-1.yaml, ms01-2.yaml, ms01-3.yaml, talosconfig

# 4. Optional: Verify disk configuration in generated files
for node in ms01-1 ms01-2 ms01-3; do
  echo "Checking $node disk config:"
  grep -A3 "install:" bootstrap/talos/clusterconfig/${node}.yaml | grep -E "disk:|diskSelector:"
done

# 5. Apply configurations to all nodes (they're in maintenance mode)
echo "📤 Applying configurations to all nodes..."
mise run apply

# This will:
# - Apply ms01-1.yaml to 192.168.169.113
# - Apply ms01-2.yaml to 192.168.169.114  
# - Apply ms01-3.yaml to 192.168.169.115
# - Nodes will reboot with their configurations

# 6. Wait for nodes to reboot and settle
echo "⏳ Waiting for nodes to reboot with new configuration..."
sleep 90

# 7. Verify nodes are back online with configs
for node in ms01-1 ms01-2 ms01-3; do
  echo -n "Checking $node: "
  talosctl -n $node -e $node version --short || echo "Still booting..."
done

# 8. Bootstrap the Kubernetes cluster
echo "🚀 Bootstrapping Kubernetes cluster..."
mise run bootstrap

# 9. Get kubeconfig
echo "📥 Fetching kubeconfig..."
mise run kubeconfig
export KUBECONFIG=/Users/kartik/workspace/kubernetes-manifests/clusters/talos-ottawa/kubeconfig

# 10. Verify cluster is up
echo "✅ Checking cluster status..."
kubectl get nodes
```

### Phase 7: Verify Thunderbolt & Install Core Components

```bash
# 1. Verify Thunderbolt connectivity
echo "🔌 Testing Thunderbolt networking..."
mise run test-thunderbolt

# Check each node has Thunderbolt interfaces
for node in ms01-1 ms01-2 ms01-3; do
  echo "Thunderbolt on $node:"
  talosctl -n $node get links | grep -E "thunderbolt|169.254" || echo "  No Thunderbolt found!"
done

# 2. Test Thunderbolt connectivity between nodes
echo "Testing ms01-1 -> ms01-2 connectivity:"
talosctl -n ms01-1 -e ms01-1 shell -- ping -c 3 169.254.255.102

echo "Testing ms01-1 -> ms01-3 connectivity:"
talosctl -n ms01-1 -e ms01-1 shell -- ping -c 3 169.254.255.103

# 3. Install Flux GitOps and CNI
echo "🔧 Installing Flux GitOps..."

# Create flux-system namespace
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

# Install Flux CRDs and controllers
kubectl apply --server-side --kustomize flux/config/

# Apply cluster configuration
kubectl apply -f flux/config/cluster.yaml

# Wait for Flux to be ready
echo "⏳ Waiting for Flux controllers..."
kubectl -n flux-system wait deployment --all --for=condition=Available --timeout=300s

# 4. Verify Flux is syncing
echo "🔄 Checking Flux sync status..."
kubectl get kustomizations -n flux-system
kubectl get gitrepositories -n flux-system
kubectl get helmreleases -A

# 5. Wait for nodes to be fully ready
echo "⏳ Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=600s

# 6. Final cluster health check
echo "🏥 Final health check..."
mise run health
kubectl get nodes -o wide
kubectl get pods -A
```

## Post-Installation Verification

### Complete Cluster Check

```bash
# 1. All nodes should be Ready
kubectl get nodes
# Expected: All 3 nodes showing "Ready"

# 2. All system pods should be running
kubectl get pods -n kube-system
kubectl get pods -n flux-system

# 3. Thunderbolt network should be functional
for node in ms01-1 ms01-2 ms01-3; do
  echo "$node Thunderbolt IPs:"
  talosctl -n $node get addresses | grep 169.254
done

# 4. Flux should be syncing
flux get sources git
flux get ks -A
```

### Performance Testing (Optional)

```bash
# Test Thunderbolt bandwidth between nodes
kubectl run iperf-server --image=networkstatic/iperf3 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"ms01-1"},"hostNetwork":true}}' \
  -- -s -B 169.254.255.101

kubectl run iperf-client --image=networkstatic/iperf3 --rm -it \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"ms01-2"},"hostNetwork":true}}' \
  -- -c 169.254.255.101 -t 10

# Expected: 20-40 Gbps depending on Thunderbolt generation
```

## Common Operations

### Quick Commands

```bash
# Check cluster status
mise run health

# Open Talos dashboard
mise run dashboard

# View logs from a node
talosctl -n ms01-1 logs kubelet

# Update configuration (edit talconfig.yaml first)
mise run genconfig
mise run apply

# Test Thunderbolt connectivity
mise run test-thunderbolt
```

### Upgrade Operations

```bash
# Upgrade Talos on a node
task -d bootstrap/talos upgrade node=ms01-1 image=ghcr.io/siderolabs/installer:v1.9.4

# Upgrade Kubernetes
task -d bootstrap/talos upgrade-k8s controller=ms01-1 to=v1.31.1
```

## Troubleshooting

### Node Not Responding After Apply

```bash
# Check console/IPMI for errors
# Try applying with insecure flag directly
talosctl apply-config --insecure -n 192.168.169.113 --file bootstrap/talos/clusterconfig/ms01-1.yaml
```

### Wrong Disk Selected

```bash
# Verify disk serial in config matches actual
grep serial bootstrap/talos/talconfig.yaml
talosctl -n NODE_IP --insecure get disks -o yaml | grep -B2 -A3 nvme1n1
```

### Thunderbolt Not Working

```bash
# 1. Verify cables are connected
# 2. Check kernel module loaded
talosctl -n ms01-1 get kernelmodulespecs | grep thunder

# 3. Check for Thunderbolt devices
talosctl -n ms01-1 shell
ls /sys/bus/thunderbolt/devices/

# 4. Check dmesg for errors
talosctl -n ms01-1 dmesg | grep -i thunder
```

### PGP/SOPS Issues - Finding Your Key

```bash
# 1. First, try to decrypt an existing file to see if SOPS can find your key
cd /Users/kartik/workspace/kubernetes-manifests/clusters/talos-ottawa
sops -d flux/vars/cluster-secrets.sops.yaml > /dev/null && echo "✅ Key is working"

# 2. If that works but GPG doesn't show the key, SOPS might be using a different method
# Check how SOPS is currently working:
sops --verbose -d flux/vars/cluster-secrets.sops.yaml 2>&1 | head -20

# 3. Common locations/methods for PGP keys:

# Standard GPG keyring
gpg --list-secret-keys

# GPG with specific home
GNUPGHOME=~/.gnupg gpg --list-secret-keys

# Check for GPG agent
gpg-connect-agent 'keyinfo --list' /bye

# 4. Find any GPG/SOPS related environment variables
env | grep -E "GPG|SOPS|PGP"

# 5. If you find your key in a non-standard location, export it:
gpg --export-secret-keys FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5 > ~/talos-pgp-key.asc

# 6. Then import it to standard location:
gpg --import ~/talos-pgp-key.asc

# 7. Trust the key
echo "FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5:6:" | gpg --import-ownertrust
```

## Directory Structure

```bash
clusters/talos-ottawa/
├── .mise.toml                    # Mise configuration
├── .sops.yaml                    # SOPS/PGP encryption rules
├── bootstrap/talos/
│   ├── talconfig.yaml            # Main configuration (UPDATE THIS)
│   ├── talsecret.sops.yaml       # PGP-encrypted Talos secrets
│   ├── clusterconfig/            # Generated configs (git-ignored)
│   ├── hardware-info/            # Gathered hardware info (reference)
│   └── patches/                  # Configuration patches
│       ├── global/               # Applied to all nodes
│       └── controller/           # Control plane only
├── flux/                         # GitOps configuration
│   └── vars/
│       └── cluster-secrets.sops.yaml  # Existing PGP-encrypted secrets
└── apps/                         # Application manifests
    └── cilium/                   # CNI configuration
```

## Quick Reference Card

### Environment Variables

```bash
export TALOSCONFIG=/Users/kartik/workspace/kubernetes-manifests/clusters/talos-ottawa/bootstrap/talos/clusterconfig/talosconfig
export KUBECONFIG=/Users/kartik/workspace/kubernetes-manifests/clusters/talos-ottawa/kubeconfig
```

### Mise Commands

| Command | Description |
|---------|-------------|
| `mise run genconfig` | Generate configurations |
| `mise run apply` | Apply configs to nodes |
| `mise run bootstrap` | Bootstrap cluster |
| `mise run kubeconfig` | Get kubeconfig |
| `mise run health` | Check health |
| `mise run dashboard` | Open dashboard |
| `mise run test-thunderbolt` | Test Thunderbolt |
| `mise run reset` | Reset cluster (DESTRUCTIVE) |

### Critical Files to Backup

Before starting fresh install, backup:
- **Your PGP private key** (`sops.asc` file) - CRITICAL! Without this, you cannot decrypt secrets
  ```bash
  # If your key is in GPG, export it:
  gpg --export-secret-keys FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5 > ~/sops-backup.asc
  # Store this file somewhere safe (password manager, secure backup, etc.)
  ```
- Any custom app configurations
- Any important data from PVCs

### Expected Timeline

- **10 min** - Workstation prep
- **15 min** - USB creation
- **20 min** - Install Talos on 3 nodes
- **10 min** - Gather hardware info
- **5 min** - Update configs
- **15 min** - Deploy and bootstrap
- **10 min** - Verify and install apps
- **Total: ~85 minutes**

## Security Notes

### Using PGP Instead of Age

This setup uses your existing PGP key (`FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5`) for SOPS encryption:
- ✅ No need to re-encrypt existing secrets
- ✅ Flux secrets work without changes
- ✅ Same encryption method across all clusters

### Files Safe to Commit
- `talconfig.yaml` - Main configuration (no secrets)
- `*.sops.yaml` - PGP-encrypted files
- `patches/**/*.yaml` - Configuration patches

### Files to NEVER Commit (git-ignored)
- `clusterconfig/` - Contains decrypted secrets
- `talsecret.yaml` - Unencrypted Talos secrets
- `hardware-info/` - May contain sensitive system info
- Your PGP private key

## Support

- [Talos Documentation](https://www.talos.dev/latest/)
- [Talhelper Documentation](https://github.com/budimanjojo/talhelper)
- [Mise Documentation](https://mise.jdx.dev/)
- [SOPS Documentation](https://github.com/getsops/sops)