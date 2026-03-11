#!/bin/bash
# Post-bootstrap setup: Tailscale, 1Password secrets, git config
# Runs as part of user-data after bootstrap.sh completes.
#
# Required env vars:
#   TS_AUTH_KEY     — Tailscale ephemeral auth key
#   INSTANCE_NAME   — hostname for Tailscale
#   REGION          — AWS region (for SSM parameter lookup)
#   OP_GITHUB_TOKEN — op:// path for GitHub token
set -euo pipefail

# ── Tailscale ──
echo "=== Joining Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey="$TS_AUTH_KEY" --hostname="$INSTANCE_NAME" --ssh
echo "Tailscale IP: $(tailscale ip -4)"

# ── 1Password: pull SA token from SSM ──
echo "=== Configuring secrets ==="
export OP_SERVICE_ACCOUNT_TOKEN=$(aws ssm get-parameter \
  --name "/agent-army/op-sa-token" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "$REGION")

# Configure git with GitHub token
GITHUB_TOKEN=$(op read "$OP_GITHUB_TOKEN")
sudo -u ubuntu bash -c "git config --global url.\"https://x-access-token:${GITHUB_TOKEN}@github.com/\".insteadOf \"https://github.com/\""

# Authenticate gh CLI
echo "$GITHUB_TOKEN" | sudo -u ubuntu bash -c 'gh auth login --with-token'

# Store OP token for ubuntu user (so they can use op read)
echo "export OP_SERVICE_ACCOUNT_TOKEN=$OP_SERVICE_ACCOUNT_TOKEN" >> /home/ubuntu/.zshrc
echo "export OP_SERVICE_ACCOUNT_TOKEN=$OP_SERVICE_ACCOUNT_TOKEN" >> /home/ubuntu/.bashrc

echo "=== Instance ready ==="
