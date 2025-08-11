#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the cluster root directory (parent of scripts)
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

export KUBECONFIG="$CLUSTER_DIR/kubeconfig"
OUTPUT_FILE="$CLUSTER_DIR/thunderbolt-results-$(date +%Y%m%d-%H%M%S).txt"

# Configurable iperf test duration (in seconds)
IPERF_DURATION="${IPERF_DURATION:-5}"

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
header "${BOLD}${GREEN}Thunderbolt Network Test - $(date)${NC}" "Thunderbolt Network Test - $(date)"
header "${CYAN}===============================================${NC}" "==============================================="
echo "" | tee -a "$OUTPUT_FILE"

# Get pods
REI_POD=$(kubectl get pods -n kube-system -l app=thunderbolt-debug -o jsonpath='{.items[?(@.spec.nodeName=="rei")].metadata.name}')
ASUKA_POD=$(kubectl get pods -n kube-system -l app=thunderbolt-debug -o jsonpath='{.items[?(@.spec.nodeName=="asuka")].metadata.name}')
KAJI_POD=$(kubectl get pods -n kube-system -l app=thunderbolt-debug -o jsonpath='{.items[?(@.spec.nodeName=="kaji")].metadata.name}')

header "${YELLOW}Pods found:${NC}" "Pods found:"
header "  ${GREEN}rei:${NC} $REI_POD" "  rei: $REI_POD"
header "  ${GREEN}asuka:${NC} $ASUKA_POD" "  asuka: $ASUKA_POD"
header "  ${GREEN}kaji:${NC} $KAJI_POD" "  kaji: $KAJI_POD"
echo "" | tee -a "$OUTPUT_FILE"

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${BLUE}PING TESTS - FULL MATRIX${NC}" "PING TESTS - FULL MATRIX"
header "${CYAN}===============================================${NC}" "==============================================="
echo "" | tee -a "$OUTPUT_FILE"

# Full ping matrix
header "${BOLD}${YELLOW}--- rei -> asuka ---${NC}" "--- rei -> asuka ---"
run_test $REI_POD -c debug -- ping -c 3 169.254.255.102
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- rei -> kaji ---${NC}" "--- rei -> kaji ---"
run_test $REI_POD -c debug -- ping -c 3 169.254.255.103
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> rei ---${NC}" "--- asuka -> rei ---"
run_test $ASUKA_POD -c debug -- ping -c 3 169.254.255.101
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> kaji ---${NC}" "--- asuka -> kaji ---"
run_test $ASUKA_POD -c debug -- ping -c 3 169.254.255.103
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> rei ---${NC}" "--- kaji -> rei ---"
run_test $KAJI_POD -c debug -- ping -c 3 169.254.255.101
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> asuka ---${NC}" "--- kaji -> asuka ---"
run_test $KAJI_POD -c debug -- ping -c 3 169.254.255.102
echo "" | tee -a "$OUTPUT_FILE"

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${BLUE}SPEED TESTS - FULL MATRIX${NC}" "SPEED TESTS - FULL MATRIX"
header "${CYAN}===============================================${NC}" "==============================================="
echo "" | tee -a "$OUTPUT_FILE"

# Full speed test matrix - all 6 combinations
header "${BOLD}${YELLOW}--- rei -> asuka ---${NC}" "--- rei -> asuka ---"
kubectl exec -n kube-system $ASUKA_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B 169.254.255.102 -1 -D" > /dev/null 2>&1 && sleep 2
run_test $REI_POD -c debug -- iperf3 -c 169.254.255.102 -t $IPERF_DURATION
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> rei ---${NC}" "--- asuka -> rei ---"
kubectl exec -n kube-system $REI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B 169.254.255.101 -1 -D" > /dev/null 2>&1 && sleep 2
run_test $ASUKA_POD -c debug -- iperf3 -c 169.254.255.101 -t $IPERF_DURATION
kubectl exec -n kube-system $REI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- rei -> kaji ---${NC}" "--- rei -> kaji ---"
kubectl exec -n kube-system $KAJI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B 169.254.255.103 -1 -D" > /dev/null 2>&1 && sleep 2
run_test $REI_POD -c debug -- iperf3 -c 169.254.255.103 -t $IPERF_DURATION
kubectl exec -n kube-system $KAJI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> rei ---${NC}" "--- kaji -> rei ---"
kubectl exec -n kube-system $REI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B 169.254.255.101 -1 -D" > /dev/null 2>&1 && sleep 2
run_test $KAJI_POD -c debug -- iperf3 -c 169.254.255.101 -t $IPERF_DURATION
kubectl exec -n kube-system $REI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- asuka -> kaji ---${NC}" "--- asuka -> kaji ---"
kubectl exec -n kube-system $KAJI_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B 169.254.255.103 -1 -D" > /dev/null 2>&1 && sleep 2
run_test $ASUKA_POD -c debug -- iperf3 -c 169.254.255.103 -t $IPERF_DURATION
kubectl exec -n kube-system $KAJI_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

header "${BOLD}${YELLOW}--- kaji -> asuka ---${NC}" "--- kaji -> asuka ---"
kubectl exec -n kube-system $ASUKA_POD -c debug -- sh -c "pkill iperf3 2>/dev/null; iperf3 -s -B 169.254.255.102 -1 -D" > /dev/null 2>&1 && sleep 2
run_test $KAJI_POD -c debug -- iperf3 -c 169.254.255.102 -t $IPERF_DURATION
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
echo "" | tee -a "$OUTPUT_FILE"

# Final cleanup
kubectl exec -n kube-system $REI_POD -c debug -- pkill iperf3 2>/dev/null || true
kubectl exec -n kube-system $ASUKA_POD -c debug -- pkill iperf3 2>/dev/null || true
kubectl exec -n kube-system $KAJI_POD -c debug -- pkill iperf3 2>/dev/null || true

header "${CYAN}===============================================${NC}" "==============================================="
header "${BOLD}${GREEN}Test completed at $(date)${NC}" "Test completed at $(date)"
header "${YELLOW}Results saved to: $OUTPUT_FILE${NC}" "Results saved to: $OUTPUT_FILE"
header "${CYAN}===============================================${NC}" "==============================================="