#!/bin/bash
# Syncs podbox .env values directly to Kubernetes secrets
# Usage:
#   bun run sync:secrets          → push directly to cluster via SSH
#   bun run sync:secrets --dry    → print what would be created without applying
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$DIR/../.." && pwd )"
DRY_RUN=false

# Load root .env
if [ -f "$ROOT_DIR/.env" ]; then
  INFRA_IP_ADDRESS=$(grep "^INFRA_IP_ADDRESS=" "$ROOT_DIR/.env" | cut -d'=' -f2-)
fi

for arg in "$@"; do
  if [ "$arg" == "--dry" ]; then DRY_RUN=true; fi
done

# -------------------------------------------------------
# Mapping: "env_file:secret-name:namespace"
# -------------------------------------------------------
MAPPINGS=(
  ".env:runner-secrets:runners"
  ".env:podbox-postgres-secrets:podbox-services"
  ".env:umami-secrets:observability"
  ".env:glitchtip-secrets:observability"
)

# Keys to pull per secret — bash 3.2 compatible (no associative arrays)
get_keys_for_secret() {
  case "$1" in
    runner-secrets)         echo "GITHUB_TOKEN GITHUB_REPO_URL" ;;
    podbox-postgres-secrets) echo "PODBOX_POSTGRES_USER PODBOX_POSTGRES_PASSWORD" ;;
    umami-secrets)          echo "UMAMI_DATABASE_URL UMAMI_APP_SECRET" ;;
    glitchtip-secrets)      echo "GLITCHTIP_DATABASE_URL GLITCHTIP_SECRET_KEY GLITCHTIP_FROM_EMAIL GLITCHTIP_EMAIL_URL" ;;
    *) echo "" ;;
  esac
}

# -------------------------------------------------------
run_cmd() {
  if [ "$DRY_RUN" == "true" ]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

apply_kubectl() {
  local yaml="$1"
  if [ "$DRY_RUN" == "true" ]; then
    echo "  [dry-run] kubectl apply -f -"
    echo "$yaml"
  else
    echo "$yaml" | ssh root@"$INFRA_IP_ADDRESS" "kubectl apply -f -"
  fi
}

sync_secret() {
  local secret_name="$1"
  local env_file="$2"
  local namespace="$3"
  local full_env_path="$ROOT_DIR/$env_file"
  local keys
  keys=$(get_keys_for_secret "$secret_name")

  echo "  Syncing → $namespace/$secret_name..."

  if [ ! -f "$full_env_path" ]; then
    echo "  ⚠️  Skipping: $env_file not found"
    return
  fi

  # Ensure namespace exists
  apply_kubectl "$(ssh root@"$INFRA_IP_ADDRESS" "kubectl create namespace $namespace --dry-run=client -o yaml" 2>/dev/null)"

  # Build --from-literal args only for the keys this secret needs
  local from_literals=""
  for key in $keys; do
    local value
    value=$(grep "^${key}=" "$full_env_path" | cut -d'=' -f2-)
    if [ -n "$value" ]; then
      from_literals+=" --from-literal=${key}=${value}"
    else
      echo "  ⚠️  Key $key is empty in $env_file — skipping this key"
    fi
  done

  if [ -z "$from_literals" ]; then
    echo "  ⚠️  No values found for $secret_name — skipping"
    return
  fi

  # Generate and apply the secret
  local yaml
  yaml=$(ssh root@"$INFRA_IP_ADDRESS" "kubectl create secret generic $secret_name \
    --namespace=$namespace \
    $from_literals \
    --dry-run=client -o yaml" 2>/dev/null)

  apply_kubectl "$yaml"
  echo "  ✅ $namespace/$secret_name synced"
}

# -------------------------------------------------------
echo "🔐 Syncing podbox secrets to cluster ($INFRA_IP_ADDRESS)..."

for mapping in "${MAPPINGS[@]}"; do
  IFS=':' read -r env_path secret_name namespace <<< "$mapping"
  sync_secret "$secret_name" "$env_path" "$namespace"
done

echo "Done!"
