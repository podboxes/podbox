#!/usr/bin/env bash
set -e

# Ensure we are running from the root of the podbox project
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR/.."

# 1. Load .env to see if INFRA_IP_ADDRESS is already defined
if [ -f .env ]; then
  # Export variables so they are available in this script
  set -a
  source .env
  set +a
fi

# 2. Prompt if not found in .env
if [ -z "$INFRA_IP_ADDRESS" ]; then
  read -p "Enter Server IP Address: " INFRA_IP_ADDRESS
fi

if [ -z "$INFRA_IP_ADDRESS" ]; then
  echo "Error: IP Address is required."
  exit 1
fi

echo "🚀 Deploying infrastructure to $INFRA_IP_ADDRESS..."

# 3. Securely copy the whole podbox folder (excluding .git) to the new server
# Rsync is much better than scp for syncing directories
rsync -avz --exclude='.git' --exclude='node_modules' . root@$INFRA_IP_ADDRESS:~/podbox

# 4. SSH in, make the script executable, load secrets, and run the Hetzner deploy script
ssh root@$INFRA_IP_ADDRESS "cd ~/podbox && chmod +x ./infra/scripts/hetzner.sh && set -a && source .env && set +a && ./infra/scripts/hetzner.sh"

# 5. Sync secrets from the personal-stack (if running from there)
if [ -d "../personal-stack" ]; then
  echo "🔐 Syncing secrets to Kubernetes..."
  (cd ../personal-stack && bun run sync:secrets) || echo "⚠️ Warning: Secrets sync skipped (local kubeseal tool not found)"
fi

# 6. Fetch Headlamp Admin Token, save to .env, and copy to system clipboard
echo "🔑 Fetching Headlamp Admin Token from cluster..."
sleep 3
TOKEN=$(ssh root@$INFRA_IP_ADDRESS "kubectl get secret headlamp-admin-token -n headlamp -o jsonpath='{.data.token}'" 2>/dev/null | base64 --decode 2>/dev/null)

if [ ! -z "$TOKEN" ]; then
  # Save to local .env in podbox
  if grep -q "HEADLAMP_TOKEN=" .env; then
    sed -i '' "s/HEADLAMP_TOKEN=.*/HEADLAMP_TOKEN=$TOKEN/" .env
  else
    echo "" >> .env
    echo "# Headlamp Admin Token" >> .env
    echo "HEADLAMP_TOKEN=$TOKEN" >> .env
  fi
  
  # Also save to personal-stack .env if it exists
  if [ -f "../personal-stack/.env" ]; then
    if grep -q "HEADLAMP_TOKEN=" ../personal-stack/.env; then
      sed -i '' "s/HEADLAMP_TOKEN=.*/HEADLAMP_TOKEN=$TOKEN/" ../personal-stack/.env
    else
      echo "" >> ../personal-stack/.env
      echo "# Headlamp Admin Token" >> ../personal-stack/.env
      echo "HEADLAMP_TOKEN=$TOKEN" >> ../personal-stack/.env
    fi
  fi
  
  # Copy to Mac clipboard
  if command -v pbcopy &> /dev/null; then
    echo -n "$TOKEN" | pbcopy
    echo "📋 Admin Token automatically copied to your clipboard!"
  fi
  
  echo -e "\n========================================================"
  echo -e "🎉 HEADLAMP IS ONLINE!"
  echo -e "URL:  https://headlamp.podbox.io"
  echo -e "========================================================\n"
else
  echo "⚠️ Could not fetch Headlamp token yet. Try running:"
  echo "  ssh root@$INFRA_IP_ADDRESS \"kubectl get secret headlamp-admin-token -n headlamp -o jsonpath='{.data.token}' | base64 --decode\""
fi

echo "✅ Deployment script completed successfully!"
