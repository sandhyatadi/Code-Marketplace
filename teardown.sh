#!/bin/bash
set -e

echo "🧹 Tearing down Coder on KIND..."

# Colors for output
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Stop port forwarding if running
if [ -f .portforward.pid ]; then
    echo -e "${BLUE}Stopping port forwarding...${NC}"
    kill $(cat .portforward.pid) 2>/dev/null || true
    rm .portforward.pid
fi

# Optional: Explicitly uninstall Helm releases before deleting cluster
# This is not strictly necessary since deleting the cluster removes everything,
# but it can be useful for debugging or if you want to see what's being removed
if kind get clusters | grep -q coder-cluster; then
    echo -e "${BLUE}Checking for Helm releases...${NC}"
    kubectl config use-context kind-coder-cluster 2>/dev/null || true
    
    # List all Helm releases across all namespaces
    echo -e "${YELLOW}Installed Helm releases:${NC}"
    helm list --all-namespaces 2>/dev/null || true
    
    # Delete code-marketplace deployment
    echo -e "${BLUE}Removing code-marketplace...${NC}"
    kubectl delete -f code-marketplace-deployment.yaml 2>/dev/null || true

    # Uninstall Coder and PostgreSQL if they exist
    helm uninstall coder -n coder 2>/dev/null || true
    helm uninstall postgres -n coder 2>/dev/null || true
fi

# Delete KIND cluster (this removes everything including all Helm releases)
echo -e "${BLUE}Deleting KIND cluster...${NC}"
kind delete cluster --name coder-cluster

# Optional: Remove Helm repositories (uncomment if you want to clean these up too)
# echo -e "${BLUE}Removing Helm repositories...${NC}"
# helm repo remove coder-v2 2>/dev/null || true
# helm repo remove bitnami 2>/dev/null || true

# Clean up any leftover files
rm -f .portforward.pid

echo -e "${RED}✅ Teardown complete!${NC}"
echo ""
echo "Note: Deleting the KIND cluster removed:"
echo "  - All Kubernetes resources"
echo "  - All Helm releases (Coder, PostgreSQL, NGINX Ingress)"
echo "  - code-marketplace deployment and extensions"
echo "  - All persistent volumes and data"
echo ""
echo "Helm repositories are still configured. To remove them, run:"
echo "  helm repo remove coder-v2"
echo "  helm repo remove bitnami"