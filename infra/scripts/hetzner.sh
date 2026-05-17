#!/usr/bin/env bash
set -e

echo "==============================================="
echo "   Podbox Infrastructure Bootstrap Script"
echo "==============================================="

# Check for required environment variables
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
  echo "Error: CLOUDFLARE_API_TOKEN environment variable is required."
  exit 1
fi

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "Error: HCLOUD_TOKEN environment variable is required for Hetzner CSI."
  exit 1
fi

echo "[1/6] Installing K3s..."
# Install K3s (skip if already installed)
if ! command -v k3s &> /dev/null; then
  curl -sfL https://get.k3s.io | sh -
  # Wait for K3s to be ready
  sleep 15
else
  echo "K3s is already installed."
fi

# Ensure kubeconfig is readable
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "[2/6] Installing Helm..."
if ! command -v helm &> /dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "Helm is already installed."
fi

echo "[3/6] Configuring Cert-Manager with Cloudflare..."
# Install Cert-Manager via Helm
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true

# Wait for Cert-Manager pods to be ready
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=300s

# Create Primary Cloudflare Secret
kubectl create secret generic cloudflare-api-token-secret \
  --namespace cert-manager \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create Secondary Cloudflare Secret if defined
if [ -n "$CLOUDFLARE_API_TOKEN_JESSEWEED" ]; then
  kubectl create secret generic cloudflare-api-token-secret-jesseweed \
    --namespace cert-manager \
    --from-literal=api-token="$CLOUDFLARE_API_TOKEN_JESSEWEED" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secondary Cloudflare token secret created."
fi

echo "[4/6] Configuring Hetzner CSI..."
# Create Hetzner Cloud Secret
kubectl create secret generic hcloud \
  --namespace kube-system \
  --from-literal=token="$HCLOUD_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Install Hetzner CSI
kubectl apply -f https://raw.githubusercontent.com/hetznercloud/csi-driver/master/deploy/kubernetes/hcloud-csi.yml

echo "[4.5/6] Configuring GitHub Container Registry..."
if [ -n "$GITHUB_USERNAME" ] && [ -n "$GITHUB_TOKEN" ]; then
  kubectl create namespace jesseweed-io --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry ghcr-login-secret \
    --docker-server=ghcr.io \
    --docker-username="$GITHUB_USERNAME" \
    --docker-password="$GITHUB_TOKEN" \
    --namespace=jesseweed-io \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "GHCR pull secret created."
else
  echo "Skipping GHCR secret (GITHUB_USERNAME or GITHUB_TOKEN not found in .env)"
fi

echo "[4.6/6] Configuring GitHub Actions Self-Hosted Runner..."
kubectl create namespace runners --dry-run=client -o yaml | kubectl apply -f -

if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_REPO_URL" ]; then
  kubectl create secret generic runner-secrets \
    --namespace=runners \
    --from-literal=GITHUB_TOKEN="$GITHUB_TOKEN" \
    --from-literal=GITHUB_REPO_URL="$GITHUB_REPO_URL" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Runner secrets created."
else
  echo "Skipping runner secrets (GITHUB_TOKEN or GITHUB_REPO_URL not set in .env)"
fi

if [ -n "$GITHUB_TOKEN" ] && [ -n "$PERSONAL_STACK_REPO_URL" ]; then
  kubectl create secret generic personal-stack-runner-secrets \
    --namespace=runners \
    --from-literal=GITHUB_TOKEN="$GITHUB_TOKEN" \
    --from-literal=GITHUB_REPO_URL="$PERSONAL_STACK_REPO_URL" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Personal-stack runner secrets created."
else
  echo "Skipping personal-stack runner secrets (PERSONAL_STACK_REPO_URL not set in .env)"
fi

echo "[4.7/6] Configuring Podbox Postgres..."
kubectl create namespace podbox-services --dry-run=client -o yaml | kubectl apply -f -

if [ -n "$PODBOX_POSTGRES_USER" ] && [ -n "$PODBOX_POSTGRES_PASSWORD" ]; then
  kubectl create secret generic podbox-postgres-secrets \
    --namespace=podbox-services \
    --from-literal=POSTGRES_USER="$PODBOX_POSTGRES_USER" \
    --from-literal=POSTGRES_PASSWORD="$PODBOX_POSTGRES_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Podbox Postgres secrets created."
else
  echo "Skipping Podbox Postgres secrets (PODBOX_POSTGRES_USER or PODBOX_POSTGRES_PASSWORD not set in .env)"
fi

echo "[4.7/6] Configuring Observability Secrets..."
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

if [ -n "$UMAMI_DATABASE_URL" ] && [ -n "$UMAMI_APP_SECRET" ]; then
  kubectl create secret generic umami-secrets \
    --namespace=observability \
    --from-literal=DATABASE_URL="$UMAMI_DATABASE_URL" \
    --from-literal=APP_SECRET="$UMAMI_APP_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Umami secrets created."
else
  echo "Skipping Umami secrets (UMAMI_DATABASE_URL or UMAMI_APP_SECRET not set in .env)"
fi

if [ -n "$GLITCHTIP_DATABASE_URL" ] && [ -n "$GLITCHTIP_SECRET_KEY" ]; then
  kubectl create secret generic glitchtip-secrets \
    --namespace=observability \
    --from-literal=DATABASE_URL="$GLITCHTIP_DATABASE_URL" \
    --from-literal=SECRET_KEY="$GLITCHTIP_SECRET_KEY" \
    --from-literal=DEFAULT_FROM_EMAIL="${GLITCHTIP_FROM_EMAIL:-noreply@podbox.io}" \
    --from-literal=EMAIL_URL="${GLITCHTIP_EMAIL_URL:-console://}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "GlitchTip secrets created."
else
  echo "Skipping GlitchTip secrets (GLITCHTIP_DATABASE_URL or GLITCHTIP_SECRET_KEY not set in .env)"
fi

echo "[5/6] Applying Kubernetes Manifests..."
# Apply in dependency order: services → runner → infra
for dir in "./k8s/services" "./k8s/runner" "./infra/manifests"; do
  if [ -d "$dir" ]; then
    echo "  Applying $dir..."
    kubectl apply -f "$dir/" --recursive
  else
    echo "  Warning: $dir not found. Skipping."
  fi
done

echo "[6/6] Bootstrap Complete!"
echo "You can monitor the status with: kubectl get pods -A"
