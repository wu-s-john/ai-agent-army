#!/bin/bash
# Terminate EC2 agent instances.
# Usage: ./scripts/terminate.sh --name agent-1
#        ./scripts/terminate.sh --instance-id i-xxx
#        ./scripts/terminate.sh --all
set -euo pipefail

REGION="us-west-1"
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
  INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
      "Name=tag:project,Values=agent-army" \
      "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)

  if [[ -z "$INSTANCE_IDS" ]]; then
    echo "No running agent-army instances found."
    exit 0
  fi

  echo "Terminating all agent-army instances:"
  for ID in $INSTANCE_IDS; do
    NAME=$(aws ec2 describe-tags \
      --region "$REGION" \
      --filters "Name=resource-id,Values=$ID" "Name=key,Values=Name" \
      --query 'Tags[0].Value' --output text 2>/dev/null || echo "unknown")
    echo "  $NAME ($ID)"
  done

  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
  echo "All instances terminated."
  exit 0
fi

# ─── Look up instance ID from name ───
if [[ -n "$INSTANCE_NAME" && -z "$INSTANCE_ID" ]]; then
  INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
      "Name=tag:Name,Values=$INSTANCE_NAME" \
      "Name=tag:project,Values=agent-army" \
      "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[0].InstanceId' \
    --output text)

  if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "ERROR: No running instance found with name '$INSTANCE_NAME'"
    exit 1
  fi
fi

# ─── Terminate ───
DISPLAY_NAME="${INSTANCE_NAME:-$INSTANCE_ID}"
echo "Terminating $DISPLAY_NAME ($INSTANCE_ID)..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
echo "$DISPLAY_NAME ($INSTANCE_ID) terminated."
