#!/bin/bash

# Advanced bond test with multiple techniques to force load balancing

CLUSTER_DIR="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"
export KUBECONFIG="$CLUSTER_DIR/kubeconfig"

REI_IP="192.168.169.118"
ASUKA_IP="192.168.169.117"
KAJI_IP="192.168.169.119"

REI_POD=$(kubectl get pods -n kube-system -l app=thunderbolt-debug -o jsonpath='{.items[?(@.spec.nodeName=="rei")].metadata.name}')
ASUKA_POD=$(kubectl get pods -n kube-system -l app=thunderbolt-debug -o jsonpath='{.items[?(@.spec.nodeName=="asuka")].metadata.name}')
KAJI_POD=$(kubectl get pods -n kube-system -l app=thunderbolt-debug -o jsonpath='{.items[?(@.spec.nodeName=="kaji")].metadata.name}')

echo "=== Testing bond load balancing ==="

# Test 1: Multiple iperf instances with different ports
echo "Test 1: Multiple iperf servers on different ports"
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true

# Start 4 servers on different ports
for port in 5201 5202 5203 5204; do
    kubectl exec -n kube-system $ASUKA_POD -c debug -- sh -c "iperf3 -s -p $port -D" &
done
sleep 3

# Run 4 clients simultaneously to different ports
echo "Starting 4 simultaneous iperf streams to different ports..."
for port in 5201 5202 5203 5204; do
    kubectl exec -n kube-system $REI_POD -c debug -- iperf3 -c $ASUKA_IP -p $port -t 15 > "/tmp/stream_$port.log" 2>&1 &
done

# Wait for completion
wait

# Show results
for port in 5201 5202 5203 5204; do
    echo "=== Stream to port $port ==="
    tail -3 "/tmp/stream_$port.log" | grep -E "(sender|receiver)"
    rm -f "/tmp/stream_$port.log"
done

# Test 2: Check if traffic is actually load balanced
echo ""
echo "Test 2: Monitor bond statistics during traffic"
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
kubectl exec -n kube-system $ASUKA_POD -c debug -- iperf3 -s -D

# Get initial stats
talosctl -n $REI_IP -e $REI_IP read /proc/net/dev | grep -E "(eth2|eth3)" > /tmp/stats_before.txt

# Run traffic
kubectl exec -n kube-system $REI_POD -c debug -- iperf3 -c $ASUKA_IP -t 10 -P 8 > /tmp/iperf_result.log &
IPERF_PID=$!

sleep 12  # Let traffic finish

# Get final stats  
talosctl -n $REI_IP -e $REI_IP read /proc/net/dev | grep -E "(eth2|eth3)" > /tmp/stats_after.txt

echo "=== Bond utilization analysis ==="
echo "Before:"
cat /tmp/stats_before.txt
echo "After:" 
cat /tmp/stats_after.txt

# Calculate differences
echo "=== Transmitted bytes delta ==="
awk 'NR==FNR{before[$1]=$10; next} {print $1, $10 - before[$1]}' /tmp/stats_before.txt /tmp/stats_after.txt

echo "=== iperf3 result ==="
tail -5 /tmp/iperf_result.log

# Cleanup
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
rm -f /tmp/stats_*.txt /tmp/iperf_result.log

echo ""
echo "=== Bond configuration ==="
talosctl -n $REI_IP -e $REI_IP read /proc/net/bonding/bond0 | grep -A2 -E "(Bonding Mode|Hash Policy|Number of ports)"