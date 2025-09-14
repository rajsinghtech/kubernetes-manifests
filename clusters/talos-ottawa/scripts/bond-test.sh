#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the cluster root directory (parent of scripts)
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

export KUBECONFIG="$CLUSTER_DIR/kubeconfig"
OUTPUT_FILE="$CLUSTER_DIR/bond-results-$(date +%Y%m%d-%H%M%S).txt"

# Configurable iperf test duration (in seconds)
IPERF_DURATION="${IPERF_DURATION:-10}"

# Node IPs for bonded network
REI_IP="192.168.169.118"
ASUKA_IP="192.168.169.117"
KAJI_IP="192.168.169.119"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Function to output headers with color to console, plain to file
header() {
    echo -e "$1"
    echo "$2" >> "$OUTPUT_FILE"
}

# Function to run command and output to both console and file
run_test() {
    kubectl exec -n kube-system "$@" 2>&1 | tee -a "$OUTPUT_FILE"
}

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${GREEN}Bonded Network Test - $(date)${NC}" "Bonded Network Test - $(date)"
header "${YELLOW}Testing 20G bonded NICs on 192.168.169.x${NC}" "Testing 20G bonded NICs on 192.168.169.x"
header "${CYAN}===============================================${NC}" "==============================================="
echo "" | tee -a "$OUTPUT_FILE"

# Get pods
REI_POD=$(kubectl get pods -n kube-system -l app=thunderbolt-debug -o jsonpath='{.items[?(@.spec.nodeName=="rei")].metadata.name}')
ASUKA_POD=$(kubectl get pods -n kube-system -l app=thunderbolt-debug -o jsonpath='{.items[?(@.spec.nodeName=="asuka")].metadata.name}')
KAJI_POD=$(kubectl get pods -n kube-system -l app=thunderbolt-debug -o jsonpath='{.items[?(@.spec.nodeName=="kaji")].metadata.name}')

header "${YELLOW}Debug pods found:${NC}" "Debug pods found:"
header "  ${GREEN}rei:${NC} $REI_POD (${REI_IP})" "  rei: $REI_POD ($REI_IP)"
header "  ${GREEN}asuka:${NC} $ASUKA_POD (${ASUKA_IP})" "  asuka: $ASUKA_POD ($ASUKA_IP)"
header "  ${GREEN}kaji:${NC} $KAJI_POD (${KAJI_IP})" "  kaji: $KAJI_POD ($KAJI_IP)"
echo "" | tee -a "$OUTPUT_FILE"

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${BLUE}PING TESTS - BONDED NETWORK${NC}" "PING TESTS - BONDED NETWORK"
header "${CYAN}===============================================${NC}" "==============================================="
echo "" | tee -a "$OUTPUT_FILE"

# Full ping matrix using bonded IPs
header "${BOLD}${YELLOW}--- rei -> asuka ---${NC}" "--- rei -> asuka ---"
run_test $REI_POD -c debug -- ping -c 3 $ASUKA_IP
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- rei -> kaji ---${NC}" "--- rei -> kaji ---"
run_test $REI_POD -c debug -- ping -c 3 $KAJI_IP
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> rei ---${NC}" "--- asuka -> rei ---"
run_test $ASUKA_POD -c debug -- ping -c 3 $REI_IP
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> kaji ---${NC}" "--- asuka -> kaji ---"
run_test $ASUKA_POD -c debug -- ping -c 3 $KAJI_IP
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> rei ---${NC}" "--- kaji -> rei ---"
run_test $KAJI_POD -c debug -- ping -c 3 $REI_IP
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> asuka ---${NC}" "--- kaji -> asuka ---"
run_test $KAJI_POD -c debug -- ping -c 3 $ASUKA_IP
echo "" | tee -a "$OUTPUT_FILE"

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${BLUE}SINGLE STREAM TESTS - BONDED NETWORK${NC}" "SINGLE STREAM TESTS - BONDED NETWORK"
header "${YELLOW}Testing single iperf3 streams${NC}" "Testing single iperf3 streams"
header "${CYAN}===============================================${NC}" "==============================================="
echo "" | tee -a "$OUTPUT_FILE"

# Single stream tests
header "${BOLD}${YELLOW}--- rei -> asuka (single stream) ---${NC}" "--- rei -> asuka (single stream) ---"
kubectl exec -n kube-system $ASUKA_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $ASUKA_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $REI_POD -c debug -- iperf3 -c $ASUKA_IP -t $IPERF_DURATION
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> rei (single stream) ---${NC}" "--- asuka -> rei (single stream) ---"
kubectl exec -n kube-system $REI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $REI_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $ASUKA_POD -c debug -- iperf3 -c $REI_IP -t $IPERF_DURATION
kubectl exec -n kube-system $REI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- rei -> kaji (single stream) ---${NC}" "--- rei -> kaji (single stream) ---"
kubectl exec -n kube-system $KAJI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $KAJI_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $REI_POD -c debug -- iperf3 -c $KAJI_IP -t $IPERF_DURATION
kubectl exec -n kube-system $KAJI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> rei (single stream) ---${NC}" "--- kaji -> rei (single stream) ---"
kubectl exec -n kube-system $REI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $REI_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $KAJI_POD -c debug -- iperf3 -c $REI_IP -t $IPERF_DURATION
kubectl exec -n kube-system $REI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> kaji (single stream) ---${NC}" "--- asuka -> kaji (single stream) ---"
kubectl exec -n kube-system $KAJI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $KAJI_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $ASUKA_POD -c debug -- iperf3 -c $KAJI_IP -t $IPERF_DURATION
kubectl exec -n kube-system $KAJI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> asuka (single stream) ---${NC}" "--- kaji -> asuka (single stream) ---"
kubectl exec -n kube-system $ASUKA_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $ASUKA_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $KAJI_POD -c debug -- iperf3 -c $ASUKA_IP -t $IPERF_DURATION
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${BLUE}PARALLEL STREAM TESTS - LEVERAGING 20G BOND${NC}" "PARALLEL STREAM TESTS - LEVERAGING 20G BOND"
header "${YELLOW}Testing 4 parallel iperf3 streams to maximize bond usage${NC}" "Testing 4 parallel iperf3 streams to maximize bond usage"
header "${CYAN}===============================================${NC}" "==============================================="
echo "" | tee -a "$OUTPUT_FILE"

# Parallel stream tests to leverage bonding
header "${BOLD}${YELLOW}--- rei -> asuka (4 parallel streams) ---${NC}" "--- rei -> asuka (4 parallel streams) ---"
kubectl exec -n kube-system $ASUKA_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $ASUKA_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $REI_POD -c debug -- iperf3 -c $ASUKA_IP -t $IPERF_DURATION -P 4
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> rei (4 parallel streams) ---${NC}" "--- asuka -> rei (4 parallel streams) ---"
kubectl exec -n kube-system $REI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $REI_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $ASUKA_POD -c debug -- iperf3 -c $REI_IP -t $IPERF_DURATION -P 4
kubectl exec -n kube-system $REI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- rei -> kaji (4 parallel streams) ---${NC}" "--- rei -> kaji (4 parallel streams) ---"
kubectl exec -n kube-system $KAJI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $KAJI_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $REI_POD -c debug -- iperf3 -c $KAJI_IP -t $IPERF_DURATION -P 4
kubectl exec -n kube-system $KAJI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> rei (4 parallel streams) ---${NC}" "--- kaji -> rei (4 parallel streams) ---"
kubectl exec -n kube-system $REI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $REI_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $KAJI_POD -c debug -- iperf3 -c $REI_IP -t $IPERF_DURATION -P 4
kubectl exec -n kube-system $REI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> kaji (4 parallel streams) ---${NC}" "--- asuka -> kaji (4 parallel streams) ---"
kubectl exec -n kube-system $KAJI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $KAJI_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $ASUKA_POD -c debug -- iperf3 -c $KAJI_IP -t $IPERF_DURATION -P 4
kubectl exec -n kube-system $KAJI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> asuka (4 parallel streams) ---${NC}" "--- kaji -> asuka (4 parallel streams) ---"
kubectl exec -n kube-system $ASUKA_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $ASUKA_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $KAJI_POD -c debug -- iperf3 -c $ASUKA_IP -t $IPERF_DURATION -P 4
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${BLUE}MAXIMUM THROUGHPUT TEST - 8 PARALLEL STREAMS${NC}" "MAXIMUM THROUGHPUT TEST - 8 PARALLEL STREAMS"
header "${YELLOW}Testing 8 parallel streams for maximum bond utilization${NC}" "Testing 8 parallel streams for maximum bond utilization"
header "${CYAN}===============================================${NC}" "==============================================="
echo "" | tee -a "$OUTPUT_FILE"

# Maximum throughput tests
header "${BOLD}${YELLOW}--- rei -> asuka (8 parallel streams) ---${NC}" "--- rei -> asuka (8 parallel streams) ---"
kubectl exec -n kube-system $ASUKA_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $ASUKA_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $REI_POD -c debug -- iperf3 -c $ASUKA_IP -t $IPERF_DURATION -P 8
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> rei (8 parallel streams) ---${NC}" "--- asuka -> rei (8 parallel streams) ---"
kubectl exec -n kube-system $REI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $REI_IP -1 -D" > /dev/null 2>&1 && sleep 2
run_test $ASUKA_POD -c debug -- iperf3 -c $REI_IP -t $IPERF_DURATION -P 8
kubectl exec -n kube-system $REI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${BLUE}BIDIRECTIONAL TEST - SIMULTANEOUS TRAFFIC${NC}" "BIDIRECTIONAL TEST - SIMULTANEOUS TRAFFIC"
header "${YELLOW}Testing simultaneous bidirectional traffic${NC}" "Testing simultaneous bidirectional traffic"
header "${CYAN}===============================================${NC}" "==============================================="
echo "" | tee -a "$OUTPUT_FILE"

# Bidirectional test
header "${BOLD}${YELLOW}--- rei <-> asuka (bidirectional 4 streams each) ---${NC}" "--- rei <-> asuka (bidirectional 4 streams each) ---"
# Start servers on both ends
kubectl exec -n kube-system $REI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $REI_IP -p 5201 -D" > /dev/null 2>&1
kubectl exec -n kube-system $ASUKA_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B $ASUKA_IP -p 5202 -D" > /dev/null 2>&1
sleep 2

# Start both clients simultaneously in background
kubectl exec -n kube-system $REI_POD -c debug -- iperf3 -c $ASUKA_IP -t $IPERF_DURATION -P 4 -p 5202 > /tmp/rei_to_asuka.log 2>&1 &
REI_PID=$!
kubectl exec -n kube-system $ASUKA_POD -c debug -- iperf3 -c $REI_IP -t $IPERF_DURATION -P 4 -p 5201 > /tmp/asuka_to_rei.log 2>&1 &
ASUKA_PID=$!

# Wait for both to complete
wait $REI_PID
wait $ASUKA_PID

# Show results
header "${CYAN}rei -> asuka results:${NC}" "rei -> asuka results:"
cat /tmp/rei_to_asuka.log | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

header "${CYAN}asuka -> rei results:${NC}" "asuka -> rei results:"
cat /tmp/asuka_to_rei.log | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Cleanup
kubectl exec -n kube-system $REI_POD -c debug -- pkill iperf3 2>/dev/null || true
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
kubectl exec -n kube-system $KAJI_POD -c debug -- pkill iperf3 2>/dev/null || true
rm -f /tmp/rei_to_asuka.log /tmp/asuka_to_rei.log

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${GREEN}Bond test completed at $(date)${NC}" "Bond test completed at $(date)"
header "${YELLOW}Results saved to: $OUTPUT_FILE${NC}" "Results saved to: $OUTPUT_FILE"
header "${CYAN}Bond configuration: 802.3ad LACP, layer3+4 hash${NC}" "Bond configuration: 802.3ad LACP, layer3+4 hash"
header "${CYAN}Expected throughput: Up to ~20 Gbps with multiple streams${NC}" "Expected throughput: Up to ~20 Gbps with multiple streams"
header "${CYAN}===============================================${NC}" "==============================================="