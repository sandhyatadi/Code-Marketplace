#!/bin/bash
set -e

echo "🚀 Starting Coder on KIND setup..."

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check prerequisites
command -v docker >/dev/null 2>&1 || { echo "Docker is required but not installed. Aborting." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
command -v kind >/dev/null 2>&1 || { echo "kind is required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting." >&2; exit 1; }

# Create KIND cluster
echo -e "${BLUE}Creating KIND cluster...${NC}"
kind create cluster --config kind-config.yaml

# Wait for cluster to be ready
echo -e "${BLUE}Waiting for cluster to be ready...${NC}"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Install NGINX Ingress Controller (optional, for better routing)
echo -e "${BLUE}Installing NGINX Ingress Controller...${NC}"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

# Add Coder Helm repository
echo -e "${BLUE}Adding Coder Helm repository...${NC}"
helm repo add coder-v2 https://helm.coder.com/v2
helm repo update

# Create namespace for Coder
echo -e "${BLUE}Creating Coder namespace...${NC}"
kubectl create namespace coder || true

# Install PostgreSQL using Bitnami Helm chart
echo -e "${BLUE}Installing PostgreSQL...${NC}"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install postgres bitnami/postgresql \
  --namespace coder \
  --set auth.username=coder \
  --set auth.password=coder \
  --set auth.database=coder \
  --set primary.persistence.enabled=false \
  --set primary.resources.requests.cpu=100m \
  --set primary.resources.requests.memory=256Mi \
  --timeout 5m \
  --wait

# Wait for PostgreSQL to be fully ready
echo -e "${BLUE}Waiting for PostgreSQL to be ready...${NC}"
kubectl wait --namespace coder \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=postgresql \
  --timeout=300s

# Optional: Create database if it doesn't exist
echo -e "${BLUE}Ensuring database exists...${NC}"
kubectl exec -n coder postgres-postgresql-0 -- psql -U coder -d postgres -c "CREATE DATABASE coder;" 2>/dev/null || true

# Install Coder
echo -e "${BLUE}Installing Coder...${NC}"
helm install coder coder-v2/coder \
  --namespace coder \
  --values coder-values.yaml \
  --timeout 10m \
  --wait

# Deploy code-marketplace
echo -e "${BLUE}Deploying code-marketplace...${NC}"
# Using official Docker image (recommended for compliance)
kubectl apply -f code-marketplace-deployment-image.yaml

# OLD APPROACH (binary download via initContainer):
# kubectl apply -f code-marketplace-deployment.yaml
# This approach downloads the binary at runtime from GitHub
# Keeping this commented for reference in case you need to switch back

# Generate TLS certificate for marketplace (optional for HTTPS)
# echo -e "${BLUE}Generating TLS certificate for code-marketplace...${NC}"
# ./generate-marketplace-tls.sh

# Wait for code-marketplace to be ready
echo -e "${BLUE}Waiting for code-marketplace to be ready...${NC}"
kubectl wait --namespace coder \
  --for=condition=ready pod \
  --selector=app=code-marketplace \
  --timeout=300s

# Get initial admin password
echo -e "${BLUE}Waiting for Coder to be ready...${NC}"
kubectl wait --namespace coder \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=coder \
  --timeout=300s

# Create initial admin user
echo -e "${BLUE}Creating initial admin user...${NC}"
ADMIN_PASSWORD=$(openssl rand -base64 12)
kubectl exec -n coder deployment/coder -- coder users create \
  --email admin@localhost \
  --username admin \
  --password "$ADMIN_PASSWORD" 2>/dev/null || echo "Admin user already exists"

# Grant owner role to admin user
kubectl exec -n coder deployment/coder -- coder users roles grant \
  admin \
  owner 2>/dev/null || true

# Generate API token
echo -e "${BLUE}Generating API token...${NC}"
CODER_TOKEN=$(kubectl exec -n coder deployment/coder -- sh -c "echo '$ADMIN_PASSWORD' | coder login http://localhost:80 --username admin --password-stdin >/dev/null 2>&1 && coder tokens create --name setup-token --lifetime 8760h 2>/dev/null" || echo "")

# If token generation failed with the above method, try alternative approach
if [ -z "$CODER_TOKEN" ]; then
    echo -e "${YELLOW}Trying alternative token generation method...${NC}"
    CODER_TOKEN=$(kubectl exec -n coder deployment/coder -- coder tokens create --name setup-token --lifetime 8760h 2>/dev/null || echo "")
fi

# Save credentials to file
echo "Admin Credentials:" > coder-credentials.txt
echo "Username: admin" >> coder-credentials.txt
echo "Password: $ADMIN_PASSWORD" >> coder-credentials.txt
if [ -n "$CODER_TOKEN" ]; then
    echo "API Token: $CODER_TOKEN" >> coder-credentials.txt
else
    echo "API Token: (failed to generate - create manually after login)" >> coder-credentials.txt
fi
chmod 600 coder-credentials.txt

# Port forward to access Coder (runs in background)
echo -e "${BLUE}Setting up port forwarding...${NC}"
kubectl port-forward -n coder svc/coder 3000:80 &
PORTFORWARD_PID=$!
echo $PORTFORWARD_PID > .portforward.pid

echo -e "${GREEN}✅ Coder setup complete!${NC}"
echo ""
echo "Access Coder at: http://localhost:3000"
echo ""
echo "Admin credentials have been saved to: coder-credentials.txt"
echo "Username: admin"
echo "Password: $ADMIN_PASSWORD"
if [ -n "$CODER_TOKEN" ]; then
    echo "API Token: $CODER_TOKEN"
    echo ""
    echo "To use the API token:"
    echo "export CODER_SESSION_TOKEN=$CODER_TOKEN"
    echo "export CODER_URL=http://localhost:3000"
else
    echo ""
    echo "Note: API token generation failed. To create one manually:"
    echo "coder login http://localhost:3000"
    echo "coder tokens create --name my-token"
fi
echo ""
echo -e "${GREEN}✅ code-marketplace deployed successfully!${NC}"
echo "Marketplace URL: https://marketplace.localhost"
echo ""
echo "To populate the marketplace with extensions, run:"
echo "  ./populate-marketplace-image.sh"
echo ""
echo "To add extensions manually:"
echo "  kubectl exec -n coder \$(kubectl get pods -n coder -l app=code-marketplace -o jsonpath='{.items[0].metadata.name}') -- /opt/code-marketplace add <URL> --extensions-dir /extensions"
echo ""
echo "To stop port forwarding, run: kill \$(cat .portforward.pid)"
echo "To tear down everything, run: ./teardown.sh"