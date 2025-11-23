#!/usr/bin/env zsh

# Cluster Health Check Script
# Monitors key indicators for cluster stability issues
# Based on investigation of kaji node failure (Nov 2025)

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${(%):-%N}")" && pwd)"
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

export KUBECONFIG="$CLUSTER_DIR/kubeconfig"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Node IPs
declare -A NODE_IPS
NODE_IPS=(
    [rei]="192.168.169.118"
    [asuka]="192.168.169.117"
    [kaji]="192.168.169.119"
)

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}Kubernetes Cluster Health Check${NC}                     ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  $(date +'%Y-%m-%d %H:%M:%S %Z')                               ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo

# ============================================================================
# 1. CSI Plugin Restart Check (CRITICAL)
# ============================================================================
echo -e "${BOLD}${BLUE}[1/9] CSI Plugin Restart Counts${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CSI_ISSUE_FOUND=false

echo "RBD CSI Plugin restarts:"
kubectl get pods -n rook-ceph -l app=csi-rbdplugin -o json 2>/dev/null | \
    jq -r '.items[] | "\(.spec.nodeName)\t\(.status.containerStatuses[0].restartCount)"' | \
    while IFS=$'\t' read -r node restarts; do
        if [[ $restarts -gt 10 ]]; then
            echo -e "  ${RED}✗${NC} $node: ${RED}$restarts restarts${NC} ⚠️  HIGH"
            CSI_ISSUE_FOUND=true
        elif [[ $restarts -gt 5 ]]; then
            echo -e "  ${YELLOW}⚠${NC} $node: ${YELLOW}$restarts restarts${NC}"
        else
            echo -e "  ${GREEN}✓${NC} $node: $restarts restarts"
        fi
    done

echo
echo "CephFS CSI Plugin restarts:"
kubectl get pods -n rook-ceph -l app=csi-cephfsplugin -o json 2>/dev/null | \
    jq -r '.items[] | "\(.spec.nodeName)\t\(.status.containerStatuses[0].restartCount)"' | \
    while IFS=$'\t' read -r node restarts; do
        if [[ $restarts -gt 10 ]]; then
            echo -e "  ${RED}✗${NC} $node: ${RED}$restarts restarts${NC} ⚠️  HIGH"
            CSI_ISSUE_FOUND=true
        elif [[ $restarts -gt 5 ]]; then
            echo -e "  ${YELLOW}⚠${NC} $node: ${YELLOW}$restarts restarts${NC}"
        else
            echo -e "  ${GREEN}✓${NC} $node: $restarts restarts"
        fi
    done

echo

# ============================================================================
# 2. Ceph Cluster Health
# ============================================================================
echo -e "${BOLD}${BLUE}[2/9] Ceph Cluster Health${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CEPH_STATUS=$(kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health 2>/dev/null | awk '{print $1}')
if [[ "$CEPH_STATUS" = "HEALTH_OK" ]]; then
    echo -e "${GREEN}✓${NC} Ceph cluster: ${GREEN}HEALTH_OK${NC}"
elif [[ "$CEPH_STATUS" = "HEALTH_WARN" ]]; then
    echo -e "${YELLOW}⚠${NC} Ceph cluster: ${YELLOW}HEALTH_WARN${NC}"
    kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail 2>/dev/null | sed 's/^/  /'
else
    echo -e "${RED}✗${NC} Ceph cluster: ${RED}$CEPH_STATUS${NC}"
    kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail 2>/dev/null | sed 's/^/  /'
fi

echo
echo "Recent Ceph crashes (last 7 days):"
RECENT_CRASHES=$(kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph crash ls-new 2>/dev/null | tail -n +2)
if [[ -z "$RECENT_CRASHES" ]]; then
    echo -e "  ${GREEN}✓${NC} No new crashes"
else
    echo -e "  ${RED}✗${NC} New crashes found:"
    echo "$RECENT_CRASHES" | sed 's/^/    /'
fi

echo

# ============================================================================
# 3. Ceph Exporter Status (crashes were precursor to node failure)
# ============================================================================
echo -e "${BOLD}${BLUE}[3/9] Ceph Exporter Status${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for node in rei asuka kaji; do
    EXPORTER_POD=$(kubectl get pods -n rook-ceph -l app=rook-ceph-exporter -o json 2>/dev/null | \
        jq -r ".items[] | select(.spec.nodeName==\"$node\") | .metadata.name")

    if [[ -n "$EXPORTER_POD" ]]; then
        RESTARTS=$(kubectl get pod -n rook-ceph "$EXPORTER_POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
        STATUS=$(kubectl get pod -n rook-ceph "$EXPORTER_POD" -o jsonpath='{.status.phase}' 2>/dev/null)

        if [[ "$STATUS" = "Running" && $RESTARTS -eq 0 ]]; then
            echo -e "  ${GREEN}✓${NC} $node: Running (0 restarts)"
        elif [[ $RESTARTS -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠${NC} $node: $STATUS (${YELLOW}$RESTARTS restarts${NC})"
        else
            echo -e "  ${GREEN}✓${NC} $node: $STATUS ($RESTARTS restarts)"
        fi
    else
        echo -e "  ${RED}✗${NC} $node: exporter pod not found"
    fi
done

echo

# ============================================================================
# 4. Node Resource Usage
# ============================================================================
echo -e "${BOLD}${BLUE}[4/9] Node Resource Usage${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl top nodes 2>/dev/null | tail -n +2 | while read -r node cpu cpu_pct mem mem_pct; do
    cpu_val=${cpu_pct%\%}
    mem_val=${mem_pct%\%}

    status="${GREEN}✓${NC}"
    warning=""

    if [[ $cpu_val -gt 80 ]]; then
        status="${RED}✗${NC}"
        warning=" ${RED}HIGH CPU${NC}"
    elif [[ $cpu_val -gt 60 ]]; then
        status="${YELLOW}⚠${NC}"
        warning=" ${YELLOW}elevated${NC}"
    fi

    if [[ $mem_val -gt 80 ]]; then
        status="${RED}✗${NC}"
        warning="$warning ${RED}HIGH MEM${NC}"
    elif [[ $mem_val -gt 60 ]]; then
        status="${YELLOW}⚠${NC}"
        warning="$warning ${YELLOW}elevated${NC}"
    fi

    echo -e "  $status $node: CPU ${cpu_pct}, Memory ${mem_pct}$warning"
done

echo

# ============================================================================
# 5. Pod Distribution
# ============================================================================
echo -e "${BOLD}${BLUE}[5/9] Pod Distribution Across Nodes${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

POD_COUNTS=$(kubectl get pods --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | select(.spec.nodeName != null) | .spec.nodeName' | \
    sort | uniq -c | awk '{print $2"\t"$1}')

echo "$POD_COUNTS" | while IFS=$'\t' read -r node count; do
    if [[ $count -lt 50 ]]; then
        echo -e "  ${YELLOW}⚠${NC} $node: ${YELLOW}$count pods${NC} (under-utilized?)"
    else
        echo -e "  ${GREEN}✓${NC} $node: $count pods"
    fi
done

echo

# ============================================================================
# 6. Thunderbolt Network Errors
# ============================================================================
echo -e "${BOLD}${BLUE}[6/9] Thunderbolt Network Errors${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for node in rei asuka kaji; do
    ip=${NODE_IPS[$node]}
    RX_ERRORS=$(talosctl -n $ip -e $ip read /sys/class/net/thunderbolt0/statistics/rx_errors 2>/dev/null || echo "N/A")
    TX_ERRORS=$(talosctl -n $ip -e $ip read /sys/class/net/thunderbolt0/statistics/tx_errors 2>/dev/null || echo "N/A")

    if [[ "$RX_ERRORS" = "N/A" ]]; then
        echo -e "  ${YELLOW}⚠${NC} $node: Thunderbolt interface not found"
    elif [[ $RX_ERRORS -gt 10000 ]]; then
        echo -e "  ${RED}✗${NC} $node: RX errors: ${RED}$RX_ERRORS${NC}, TX errors: $TX_ERRORS"
    elif [[ $RX_ERRORS -gt 1000 ]]; then
        echo -e "  ${YELLOW}⚠${NC} $node: RX errors: ${YELLOW}$RX_ERRORS${NC}, TX errors: $TX_ERRORS"
    else
        echo -e "  ${GREEN}✓${NC} $node: RX errors: $RX_ERRORS, TX errors: $TX_ERRORS"
    fi
done

echo

# ============================================================================
# 7. Bond Interface Errors
# ============================================================================
echo -e "${BOLD}${BLUE}[7/9] Bond Interface Errors${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for node in rei asuka kaji; do
    ip=${NODE_IPS[$node]}
    RX_ERRORS=$(talosctl -n $ip -e $ip read /sys/class/net/bond0/statistics/rx_errors 2>/dev/null || echo "N/A")
    TX_ERRORS=$(talosctl -n $ip -e $ip read /sys/class/net/bond0/statistics/tx_errors 2>/dev/null || echo "N/A")

    if [[ "$RX_ERRORS" = "N/A" ]]; then
        echo -e "  ${RED}✗${NC} $node: Cannot read bond0 stats"
    elif [[ $RX_ERRORS -gt 0 || $TX_ERRORS -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠${NC} $node: RX errors: ${YELLOW}$RX_ERRORS${NC}, TX errors: ${YELLOW}$TX_ERRORS${NC}"
    else
        echo -e "  ${GREEN}✓${NC} $node: RX errors: $RX_ERRORS, TX errors: $TX_ERRORS"
    fi
done

echo

# ============================================================================
# 8. Failed/Crashing Pods
# ============================================================================
echo -e "${BOLD}${BLUE}[8/9] Failed or Crashing Pods${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FAILED_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | tail -n +2)

if [[ -z "$FAILED_PODS" ]]; then
    echo -e "${GREEN}✓${NC} No failed or pending pods"
else
    echo -e "${RED}✗${NC} Failed/Pending pods found:"
    echo "$FAILED_PODS" | sed 's/^/  /'
fi

echo
CRASHLOOP_PODS=$(kubectl get pods --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.containerStatuses != null) | select(.status.containerStatuses[].restartCount > 5) | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.nodeName)\t\(.status.containerStatuses[0].restartCount)"')

if [[ -n "$CRASHLOOP_PODS" ]]; then
    echo -e "${YELLOW}⚠${NC} Pods with high restart counts (>5):"
    echo "$CRASHLOOP_PODS" | while IFS=$'\t' read -r ns name node restarts; do
        echo -e "  ${YELLOW}⚠${NC} $ns/$name on $node: ${YELLOW}$restarts restarts${NC}"
    done
else
    echo -e "${GREEN}✓${NC} No pods with excessive restarts"
fi

echo

# ============================================================================
# 9. Recent Kernel Errors (on kaji specifically)
# ============================================================================
echo -e "${BOLD}${BLUE}[9/9] Recent Kernel Errors on kaji${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

KAJI_IP=${NODE_IPS[kaji]}
KAJI_ERRORS=$(talosctl -n $KAJI_IP -e $KAJI_IP dmesg 2>/dev/null | \
    grep -i -E "(error|fail|segfault|oom)" | \
    grep -v "controller failed" | \
    tail -10)

if [[ -z "$KAJI_ERRORS" ]]; then
    echo -e "${GREEN}✓${NC} No recent kernel errors"
else
    echo -e "${YELLOW}⚠${NC} Recent kernel messages:"
    echo "$KAJI_ERRORS" | sed 's/^/  /'
fi

echo
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Health Check Complete${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "${BOLD}Key Indicators to Watch:${NC}"
echo -e "  • CSI plugin restarts on kaji (restart every ~2 days = problem returning)"
echo -e "  • Ceph exporter crashes (precursor to node failure)"
echo -e "  • Network errors on bond0 or Thunderbolt interfaces"
echo -e "  • Kernel segfaults or OOM messages"
echo
