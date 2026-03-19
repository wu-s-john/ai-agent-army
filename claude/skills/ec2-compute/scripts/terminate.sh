#!/bin/bash
# Terminate EC2 agent instances.
# Usage: ./scripts/terminate.sh --name agent-1
#        ./scripts/terminate.sh --instance-id i-xxx
#        ./scripts/terminate.sh --all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Find which region an instance is in
find_instance_region() {
  local filter_name="$1"
  local filter_value="$2"
  for r in "${REGIONS[@]}"; do
    local result
    result=$(aws ec2 describe-instances \
      --region "$r" \
      --filters \
        "Name=$filter_name,Values=$filter_value" \
        "Name=tag:project,Values=agent-army" \
        "Name=instance-state-name,Values=running,pending" \
      --query 'Reservations[].Instances[0].InstanceId' \
      --output text 2>/dev/null || echo "")
    if [[ -n "$result" && "$result" != "None" ]]; then
      echo "$r"
      return 0
    fi
  done
  echo ""
}

REGION=""
TS_API_KEY="${TS_API_KEY:-$(op read "op://ai-agent-army/Tailscale/api_key" 2>/dev/null || echo "")}"
TS_TAILNET="${TS_TAILNET:-$(tailscale status --json 2>/dev/null | jq -r '.CurrentTailnet.Name' || echo "")}"

# Remove a Tailscale node by hostname (tries SSH logout first, then API delete)
# Get the OS tag for an instance to determine SSH user
get_instance_os() {
  local instance_id="$1"
  aws ec2 describe-tags \
    --region "$REGION" \
    --filters "Name=resource-id,Values=$instance_id" "Name=key,Values=os" \
    --query 'Tags[0].Value' --output text 2>/dev/null || echo "linux"
}

get_ssh_user() {
  local os_tag="$1"
  if [[ "$os_tag" == "macos" ]]; then
    echo "ec2-user"
  else
    echo "ubuntu"
  fi
}

# Remove a Tailscale node by hostname (tries SSH logout first, then API delete)
remove_tailscale_node() {
  local name="$1"
  local ssh_user="${2:-ubuntu}"
  echo "Removing Tailscale node for $name..."
  # Try graceful logout via SSH first
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$ssh_user@$name" \
    "sudo tailscale logout" 2>/dev/null; then
    echo "  Tailscale node logged out via SSH."
    return 0
  fi
  # Fallback: remove via Tailscale API
  if [[ -n "$TS_API_KEY" && -n "$TS_TAILNET" ]]; then
    local device_id
    device_id=$(curl -s -H "Authorization: Bearer $TS_API_KEY" \
      "https://api.tailscale.com/api/v2/tailnet/$TS_TAILNET/devices" \
      | jq -r ".devices[] | select(.hostname == \"$name\") | .id" 2>/dev/null || echo "")
    if [[ -n "$device_id" ]]; then
      curl -s -X DELETE -H "Authorization: Bearer $TS_API_KEY" \
        "https://api.tailscale.com/api/v2/device/$device_id" >/dev/null
      echo "  Tailscale node removed via API."
      return 0
    fi
  fi
  echo "  (could not remove Tailscale node — may need manual cleanup)"
}
INSTANCE_NAME=""
INSTANCE_ID=""
TERMINATE_ALL=false

# ─── Parse args ───
while [[ $# -gt 0 ]]; do
  case $1 in
    --name) INSTANCE_NAME="$2"; shift 2 ;;
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --all) TERMINATE_ALL=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_NAME" && -z "$INSTANCE_ID" && "$TERMINATE_ALL" == false ]]; then
  echo "Usage: ./scripts/terminate.sh --name <name>"
  echo "       ./scripts/terminate.sh --instance-id <id>"
  echo "       ./scripts/terminate.sh --all"
  exit 1
fi

# ─── Terminate all ───
if [[ "$TERMINATE_ALL" == true ]]; then
  FOUND_ANY=false
  for REGION in "${REGIONS[@]}"; do
    INSTANCE_IDS=$(aws ec2 describe-instances \
      --region "$REGION" \
      --filters \
        "Name=tag:project,Values=agent-army" \
        "Name=instance-state-name,Values=running,pending" \
      --query 'Reservations[].Instances[].InstanceId' \
      --output text 2>/dev/null || echo "")

    if [[ -z "$INSTANCE_IDS" ]]; then
      continue
    fi
    FOUND_ANY=true

    echo "Terminating agent-army instances in $REGION:"
    for ID in $INSTANCE_IDS; do
      NAME=$(aws ec2 describe-tags \
        --region "$REGION" \
        --filters "Name=resource-id,Values=$ID" "Name=key,Values=Name" \
        --query 'Tags[0].Value' --output text 2>/dev/null || echo "unknown")
      echo "  $NAME ($ID)"
      if [[ "$NAME" != "unknown" ]]; then
        OS_TAG=$(get_instance_os "$ID")
        SSH_USER=$(get_ssh_user "$OS_TAG")
        remove_tailscale_node "$NAME" "$SSH_USER"
      fi
    done

    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
    echo "Instances in $REGION terminated."
  done

  if [[ "$FOUND_ANY" == false ]]; then
    echo "No running agent-army instances found."
    exit 0
  fi
  echo ""
  echo "NOTE: If any Mac instances were terminated, dedicated hosts may still be allocated."
  echo "Release with: ~/.claude/skills/ec2-compute/scripts/release-mac-host.sh"
  exit 0
fi

# ─── Look up instance ID from name ───
if [[ -n "$INSTANCE_NAME" && -z "$INSTANCE_ID" ]]; then
  REGION=$(find_instance_region "tag:Name" "$INSTANCE_NAME")
  if [[ -z "$REGION" ]]; then
    echo "ERROR: No running instance found with name '$INSTANCE_NAME' in any region"
    exit 1
  fi
  INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
      "Name=tag:Name,Values=$INSTANCE_NAME" \
      "Name=tag:project,Values=agent-army" \
      "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[0].InstanceId' \
    --output text)
fi

# ─── Remove Tailscale node ───
DISPLAY_NAME="${INSTANCE_NAME:-$INSTANCE_ID}"
OS_TAG=$(get_instance_os "$INSTANCE_ID")
SSH_USER=$(get_ssh_user "$OS_TAG")

if [[ -n "$INSTANCE_NAME" ]]; then
  remove_tailscale_node "$INSTANCE_NAME" "$SSH_USER"
fi

# ─── Terminate ───
echo "Terminating $DISPLAY_NAME ($INSTANCE_ID)..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
echo "$DISPLAY_NAME ($INSTANCE_ID) terminated."

if [[ "$OS_TAG" == "macos" ]]; then
  echo ""
  echo "NOTE: Dedicated host is still allocated (24-hr minimum)."
  echo "  Wait ~5-10 min for Mac instance to fully release, then run:"
  echo "  ~/.claude/skills/ec2-compute/scripts/release-mac-host.sh"
fi
