#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Injecting secrets from 1Password..."
op inject -i "$REPO_DIR/dotfiles/env-secrets.sh.tmpl" -o "$HOME/.env-secrets.sh"
chmod 600 "$HOME/.env-secrets.sh"
echo "Done. Secrets written to ~/.env-secrets.sh (will load on next shell session)."
