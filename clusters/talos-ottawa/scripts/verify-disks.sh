#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the cluster root directory (parent of scripts)
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Verifying Disk Configuration ==="
echo "Looking for which disks are configured for each node..."
echo ""

for node in rei asuka kaji; do
    echo "Node: $node"
    
    # Get the serial from the generated config
    config_file="$CLUSTER_DIR/bootstrap/talos/clusterconfig/k8s.ottawa.local-${node}.yaml"
    if [ -f "$config_file" ]; then
        serial=$(grep -A2 "diskSelector:" "$config_file" | grep "serial:" | sed 's/.*serial: *//')
        echo "  Configured serial: $serial"
        
        # Look up what this disk actually is
        hw_file="$CLUSTER_DIR/hardware-info/${node}-disks.yaml"
        if [ -f "$hw_file" ] && [ -n "$serial" ]; then
            # Use grep with context to find the disk block
            disk_info=$(grep -B10 -A5 "serial: $serial" "$hw_file")
            
            # Extract the info we care about
            model=$(echo "$disk_info" | grep "model:" | sed 's/.*model: *//')
            size=$(echo "$disk_info" | grep "pretty_size:" | sed 's/.*pretty_size: *//')
            path=$(echo "$disk_info" | grep "dev_path:" | sed 's/.*dev_path: *//')
            
            if [ -n "$model" ]; then
                echo "  This disk is: $path"
                echo "    Model: $model"
                echo "    Size: $size"
            else
                echo "  Could not find disk info for serial: $serial"
            fi
        else
            echo "  No hardware info available (run hardware gathering first)"
        fi
    else
        echo "  Config file not found: $config_file"
    fi
    echo ""
done