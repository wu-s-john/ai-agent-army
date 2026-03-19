#!/bin/bash
# Release idle Mac dedicated hosts across all regions.
# Usage: ./scripts/release-mac-host.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

FOUND_ANY=false

for REGION in "${REGIONS[@]}"; do
  # Find all agent-army dedicated hosts (both available and occupied)
  ALL_HOSTS=$(aws ec2 describe-hosts \
    --region "$REGION" \
    --filter \
      "Name=tag:project,Values=agent-army" \
    --query 'Hosts[].{Id:HostId,State:State,Type:HostProperties.InstanceType,Instances:Instances[].InstanceId}' \
    --output json 2>/dev/null || echo "[]")

  HOST_COUNT=$(echo "$ALL_HOSTS" | jq length)
  if [[ "$HOST_COUNT" -eq 0 ]]; then
    continue
  fi

  echo "=== $REGION ==="
  for i in $(seq 0 $((HOST_COUNT - 1))); do
    HID=$(echo "$ALL_HOSTS" | jq -r ".[$i].Id")
    STATE=$(echo "$ALL_HOSTS" | jq -r ".[$i].State")
    TYPE=$(echo "$ALL_HOSTS" | jq -r ".[$i].Type")
    INSTANCE_IDS=$(echo "$ALL_HOSTS" | jq -r ".[$i].Instances // [] | join(\", \")")
    FOUND_ANY=true

    if [[ "$STATE" == "available" ]]; then
      echo "Releasing $TYPE dedicated host $HID..."
      if aws ec2 release-hosts --host-ids "$HID" --region "$REGION" 2>/dev/null; then
        echo "  Released."
      else
        echo "  Failed — host may still be within 24-hour minimum allocation period."
      fi
    else
      echo "SKIPPING $TYPE dedicated host $HID — state: $STATE"
      if [[ -n "$INSTANCE_IDS" ]]; then
        echo "  Occupied by: $INSTANCE_IDS"
        echo "  Terminate the instance first, then wait for it to fully release (~5-10 min for Mac)."
        echo "  Then re-run this script."
      fi
    fi
  done
  echo ""
done

if [[ "$FOUND_ANY" == false ]]; then
  echo "No dedicated hosts found in any region."
fi
