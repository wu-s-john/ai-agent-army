#!/bin/bash
# Show status of all running agent-army EC2 instances.
# Usage: ./scripts/status.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
IDLE_CPU_THRESHOLD="10.0"  # CPU load avg below this = idle

# Hourly costs
get_cost() {
  case "$1" in
    t3.medium)        echo "0.042" ;;
    t3.large)         echo "0.083" ;;
    t3.xlarge)        echo "0.166" ;;
    c7i.2xlarge)      echo "0.357" ;;
    mac2.metal)       echo "6.500" ;;
    mac2-m2pro.metal) echo "10.440" ;;
    *)                echo "0.000" ;;
  esac
}

# ─── Get running instances across all regions ───
INSTANCES_JSON="[]"
for REGION in "${REGIONS[@]}"; do
  REGION_JSON=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
      "Name=tag:project,Values=agent-army" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,LaunchTime:LaunchTime,Name:Tags[?Key==`Name`]|[0].Value,Os:Tags[?Key==`os`]|[0].Value}' \
    --output json 2>/dev/null || echo "[]")
  INSTANCES_JSON=$(echo "$INSTANCES_JSON $REGION_JSON" | jq -s 'add')
done

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
  OS_TAG=$(echo "$INSTANCES_JSON" | jq -r ".[$i].Os // \"linux\"")
  COST="$(get_cost "$TYPE")"
  TOTAL_COST=$(echo "$TOTAL_COST + $COST" | bc)

  # Determine SSH user and stats command based on OS
  if [[ "$OS_TAG" == "macos" ]]; then
    SSH_USER="ec2-user"
    STATS_CMD="echo CPU:\$(sysctl -n vm.loadavg | awk '{print \$2}') && \
      vm_stat | awk '/Pages active/{gsub(/\\./,\"\",\$3);a=\$3}/Pages wired/{gsub(/\\./,\"\",\$4);w=\$4}END{printf \"RAM:%d/16384\", (a+w)*16384/1048576}' && \
      echo '' && uptime"
  else
    SSH_USER="ubuntu"
    STATS_CMD="echo CPU:\$(awk '{print \$1}' /proc/loadavg) && \
      free -m | awk '/Mem:/{printf \"RAM:%s/%s\", \$3, \$2}' && \
      echo '' && uptime -p"
  fi

  # Try to get stats via SSH (timeout 5s)
  STATUS="UNREACHABLE"
  CPU_DISPLAY="?"
  RAM_DISPLAY="?"
  UPTIME_DISPLAY="?"

  if STATS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$NAME" \
    "$STATS_CMD" 2>/dev/null); then

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
