#!/usr/bin/env zsh

# Get the directory where this script is located
SCRIPT_DIR="${0:A:h}"
# Get the cluster root directory (parent of scripts)
CLUSTER_DIR="${SCRIPT_DIR:h}"

echo "=== Verifying Disk Configuration ==="
echo "Looking for which disks are configured for each node..."
echo ""

for node in rei asuka kaji; do
    echo "Node: $node"
    echo "========================================="
    
    # Get the serial from the generated config
    config_file="$CLUSTER_DIR/bootstrap/talos/clusterconfig/k8s.ottawa.local-${node}.yaml"
    if [[ -f "$config_file" ]]; then
        # Extract serial number
        serial=$(/usr/bin/grep -A2 "diskSelector:" "$config_file" | /usr/bin/grep "serial:" | /usr/bin/sed 's/.*serial: *//')
        echo "  Configured for installation:"
        echo "    Serial: $serial"
        
        # Look up what this disk actually is
        hw_file="$CLUSTER_DIR/hardware-info/${node}-disks.yaml"
        if [[ -f "$hw_file" ]] && [[ -n "$serial" ]]; then
            # Use grep with context to find the disk block
            disk_info=$(/usr/bin/grep -B10 -A5 "serial: $serial" "$hw_file")
            
            # Extract the info we care about
            model=$(echo "$disk_info" | /usr/bin/grep "model:" | /usr/bin/sed 's/.*model: *//')
            size=$(echo "$disk_info" | /usr/bin/grep "pretty_size:" | /usr/bin/sed 's/.*pretty_size: *//')
            path=$(echo "$disk_info" | /usr/bin/grep "dev_path:" | /usr/bin/sed 's/.*dev_path: *//')
            
            if [[ -n "$model" ]]; then
                echo "    Path: $path"
                echo "    Model: $model"
                echo "    Size: $size"
            else
                echo "    Could not find disk info for serial: $serial"
            fi
        else
            echo "    No hardware info available (run hardware gathering first)"
        fi
        
        # Now show all NVMe disks available on this node
        echo ""
        echo "  All NVMe disks on this node:"
        if [[ -f "$hw_file" ]]; then
            # Process each nvme disk
            /usr/bin/grep "id: nvme" "$hw_file" | while read -r line; do
                # Extract disk ID
                disk_id=${line#*id: }
                
                # Get disk details - get the full block for this disk
                disk_start=$(/usr/bin/grep -n "id: $disk_id" "$hw_file" | /usr/bin/cut -d: -f1)
                if [[ -n "$disk_start" ]]; then
                    # Get 20 lines starting from this disk
                    disk_block=$(/usr/bin/tail -n +$disk_start "$hw_file" | /usr/bin/head -n 20)
                    
                    # Extract fields from the block
                    dev_path=$(echo "$disk_block" | /usr/bin/grep "dev_path:" | /usr/bin/sed 's/.*dev_path: *//')
                    model=$(echo "$disk_block" | /usr/bin/grep "model:" | /usr/bin/sed 's/.*model: *//')
                    serial_disk=$(echo "$disk_block" | /usr/bin/grep "serial:" | /usr/bin/sed 's/.*serial: *//')
                    size=$(echo "$disk_block" | /usr/bin/grep "pretty_size:" | /usr/bin/sed 's/.*pretty_size: *//')
                    
                    # Get manufacturer from model name
                    manufacturer="Unknown"
                    if [[ "$model" =~ "Samsung" ]]; then
                        manufacturer="Samsung"
                    elif [[ "$model" =~ "KINGSTON" ]]; then
                        manufacturer="Kingston"
                    elif [[ "$model" =~ "WD" ]] || [[ "$model" =~ "Western Digital" ]]; then
                        manufacturer="Western Digital"
                    elif [[ "$model" =~ "Crucial" ]]; then
                        manufacturer="Crucial"
                    elif [[ "$model" =~ "Intel" ]]; then
                        manufacturer="Intel"
                    elif [[ "$model" =~ "Seagate" ]]; then
                        manufacturer="Seagate"
                    elif [[ "$model" =~ "Toshiba" ]]; then
                        manufacturer="Toshiba"
                    fi
                    
                    # Display disk info
                    if [[ "$serial_disk" = "$serial" ]]; then
                        echo "    $dev_path: $model ($size) [*** CONFIGURED FOR OS ***]"
                        echo "      Manufacturer: $manufacturer"
                        echo "      Serial: $serial_disk"
                    else
                        echo "    $dev_path: $model ($size)"
                        echo "      Manufacturer: $manufacturer"
                        echo "      Serial: $serial_disk"
                    fi
                    echo ""
                fi
            done
            
            # Check if any disks were found
            if ! /usr/bin/grep -q "id: nvme" "$hw_file"; then
                echo "    No NVMe disks found"
            fi
        else
            echo "    Hardware info file not found: $hw_file"
        fi
    else
        echo "  Config file not found: $config_file"
    fi
    echo ""
done