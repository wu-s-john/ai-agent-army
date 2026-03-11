#!/bin/bash
# Show status of all running agent-army EC2 instances.
# Usage: ./scripts/status.sh
set -euo pipefail

REGION="us-west-1"
IDLE_CPU_THRESHOLD="10.0"  # CPU load avg below this = idle

# Hourly costs
declare -A COSTS=(
  ["t3.medium"]="0.042"
  ["t3.large"]="0.083"
  ["t3.xlarge"]="0.166"
  ["c7i.2xlarge"]="0.357"
)

# ─── Get running instances ───
INSTANCES_JSON=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:project,Values=agent-army" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,LaunchTime:LaunchTime,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output json)

INSTANCE_COUNT=$(echo "$INSTANCES_JSON" | jq length)

if [[ "$INSTANCE_COUNT" -eq 0 ]]; then
  echo "No running agent-army instances."
  exit 0
fi

echo "INSTANCES:"
echo ""

IDLE_COUNT=0
BUSY_COUNT=0
TOTAL_COST=0

for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
  NAME=$(echo "$INSTANCES_JSON" | jq -r ".[$i].Name // \"unknown\"")
  TYPE=$(echo "$INSTANCES_JSON" | jq -r ".[$i].Type")
  ID=$(echo "$INSTANCES_JSON" | jq -r ".[$i].Id")
  LAUNCH=$(echo "$INSTANCES_JSON" | jq -r ".[$i].LaunchTime")
  COST="${COSTS[$TYPE]:-0.000}"
  TOTAL_COST=$(echo "$TOTAL_COST + $COST" | bc)

  # Try to get stats via SSH (timeout 5s)
  STATUS="UNREACHABLE"
  CPU_DISPLAY="?"
  RAM_DISPLAY="?"
  UPTIME_DISPLAY="?"

  if STATS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$NAME" \
    "echo CPU:\$(awk '{print \$1}' /proc/loadavg) && \
     free -m | awk '/Mem:/{printf \"RAM:%s/%s\", \$3, \$2}' && \
     echo '' && \
     uptime -p" 2>/dev/null); then

    CPU_LOAD=$(echo "$STATS" | grep '^CPU:' | cut -d: -f2)
    RAM_INFO=$(echo "$STATS" | grep '^RAM:' | cut -d: -f2)
    UPTIME_DISPLAY=$(echo "$STATS" | grep '^up ' || echo "unknown")

    RAM_USED=$(echo "$RAM_INFO" | cut -d/ -f1)
    RAM_TOTAL=$(echo "$RAM_INFO" | cut -d/ -f2)
    RAM_DISPLAY="${RAM_USED}/${RAM_TOTAL} MB"

    CPU_DISPLAY="${CPU_LOAD}"

    # Determine idle/busy
    IS_IDLE=$(echo "$CPU_LOAD < $IDLE_CPU_THRESHOLD" | bc -l 2>/dev/null || echo "0")
    if [[ "$IS_IDLE" == "1" ]]; then
      STATUS="IDLE"
      IDLE_COUNT=$((IDLE_COUNT + 1))
    else
      STATUS="BUSY"
      BUSY_COUNT=$((BUSY_COUNT + 1))
    fi
  else
    BUSY_COUNT=$((BUSY_COUNT + 1))  # can't reach = assume busy/booting
    STATUS="BOOTING"
  fi

  printf "  %-14s %-14s %-10s CPU: %-6s RAM: %-14s %s  %s\n" \
    "$NAME" "$TYPE" "$ID" "$CPU_DISPLAY" "$RAM_DISPLAY" "$UPTIME_DISPLAY" "$STATUS"
done

echo ""
echo "  Idle: $IDLE_COUNT  |  Busy: $BUSY_COUNT  |  Total: $INSTANCE_COUNT  |  Cost: ~\$${TOTAL_COST}/hr"
