#!/bin/bash
# Launch an EC2 instance with bootstrap, Tailscale, and 1Password configured.
# Usage: ./scripts/launch.sh --name agent-1 [--type t3.xlarge]
set -euo pipefail

# Load 1Password secret paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../secrets.env"

# Shared config
source "$SCRIPT_DIR/config.sh"

# Defaults
INSTANCE_TYPE="t3.xlarge"
INSTANCE_NAME=""
INSTANCE_PROFILE="agent-instance-role"

DEFAULT_REGION="eu-west-1"

# ─── Per-region infrastructure (discovered via tags) ───
get_subnet() {
  aws ec2 describe-subnets --region "$1" \
    --filters "Name=tag:project,Values=$PROJECT_TAG" \
    --query 'Subnets[0].SubnetId' --output text
}
get_sg() {
  aws ec2 describe-security-groups --region "$1" \
    --filters "Name=tag:project,Values=$PROJECT_TAG" \
    --query 'SecurityGroups[0].GroupId' --output text
}
get_az() {
  aws ec2 describe-subnets --region "$1" \
    --filters "Name=tag:project,Values=$PROJECT_TAG" \
    --query 'Subnets[0].AvailabilityZone' --output text
}

# ─── Instance type to region mapping ───
# Mac instances default to eu-west-1 (confirmed capacity).
# us-west-2 and us-east-1 had InsufficientHostCapacity for mac2.metal as of 2026-03.
get_region_for_type() {
  case "$1" in
    mac2.metal|mac2-m2pro.metal) echo "eu-west-1" ;;
    *)                           echo "$DEFAULT_REGION" ;;
  esac
}

# Hourly costs for display
get_cost() {
  case "$1" in
    t3.medium)       echo "0.042" ;;
    t3.large)        echo "0.083" ;;
    t3.xlarge)       echo "0.166" ;;
    c7i.2xlarge)     echo "0.357" ;;
    mac2.metal)      echo "6.500" ;;
    mac2-m2pro.metal) echo "10.440" ;;
    *)               echo "unknown" ;;
  esac
}

# ─── Parse args ───
REGION_OVERRIDE=""
USE_FRESH=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --name) INSTANCE_NAME="$2"; shift 2 ;;
    --type) INSTANCE_TYPE="$2"; shift 2 ;;
    --region) REGION_OVERRIDE="$2"; shift 2 ;;
    --fresh) USE_FRESH=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_NAME" ]]; then
  echo "Usage: ./scripts/launch.sh --name <name> [--type <instance-type>] [--region <region>] [--fresh]"
  echo ""
  echo "Linux instance types:"
  echo "  t3.medium    (2 vCPU,  4 GB) - \$0.042/hr"
  echo "  t3.large     (2 vCPU,  8 GB) - \$0.083/hr"
  echo "  t3.xlarge    (4 vCPU, 16 GB) - \$0.166/hr  [default]"
  echo "  c7i.2xlarge  (8 vCPU, 16 GB) - \$0.357/hr"
  echo ""
  echo "macOS instance types (dedicated host, 24-hr minimum):"
  echo "  mac2.metal       (M1,     8 core, 16 GB) - \$6.500/hr"
  echo "  mac2-m2pro.metal (M2 Pro, 12 core, 32 GB) - \$10.440/hr"
  echo ""
  echo "Options:"
  echo "  --fresh    Force stock Ubuntu AMI (skip pre-baked)"
  exit 1
fi

# ─── Resolve region and infrastructure ───
if [[ -n "$REGION_OVERRIDE" ]]; then
  REGION="$REGION_OVERRIDE"
else
  REGION="$(get_region_for_type "$INSTANCE_TYPE")"
fi

SUBNET_ID="$(get_subnet "$REGION")"
SG_ID="$(get_sg "$REGION")"
AZ="$(get_az "$REGION")"

# Validate region has infrastructure
if [[ -z "$SUBNET_ID" ]]; then
  echo "ERROR: No infrastructure found for region $REGION"
  echo "Tag a subnet and security group with project=$PROJECT_TAG in $REGION"
  exit 1
fi

echo "Region: $REGION (AZ: $AZ)"

# ─── Detect macOS vs Linux from instance type ───
IS_MAC=false
case "$INSTANCE_TYPE" in mac*) IS_MAC=true ;; esac

if [[ "$IS_MAC" == true ]]; then
  AGENT_USER="ec2-user"
  USER_HOME="/Users/ec2-user"
  OS_TAG="macos"
else
  AGENT_USER="ubuntu"
  USER_HOME="/home/ubuntu"
  OS_TAG="linux"
fi

COST="$(get_cost "$INSTANCE_TYPE")"
echo "=== Launching $INSTANCE_NAME ($INSTANCE_TYPE, ~\$$COST/hr) ==="

# ─── Find AMI ───
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$IS_MAC" == true ]]; then
  echo "Finding latest macOS Sonoma arm64 AMI..."
  AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters \
      "Name=name,Values=amzn-ec2-macos-14*" \
      "Name=architecture,Values=arm64_mac" \
      "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)
else
  USING_BAKED_AMI=false
  if [[ "$USE_FRESH" != true ]]; then
    echo "Checking for pre-baked Linux AMI..."
    AMI_ID=$(aws ec2 describe-images \
      --region "$REGION" \
      --owners self \
      --filters \
        "Name=tag:project,Values=$PROJECT_TAG" \
        "Name=tag:os,Values=linux" \
        "Name=state,Values=available" \
      --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
      --output text 2>/dev/null || echo "None")
    if [[ -n "$AMI_ID" && "$AMI_ID" != "None" ]]; then
      USING_BAKED_AMI=true
      echo "Using pre-baked AMI: $AMI_ID"
    fi
  fi

  if [[ "$USING_BAKED_AMI" != true ]]; then
    echo "Finding latest Ubuntu amd64 AMI..."
    AMI_ID=$(aws ec2 describe-images \
      --region "$REGION" \
      --owners 099720109477 \
      --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
      --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
      --output text)
  fi
fi
echo "AMI: $AMI_ID"

# ─── Dedicated host (macOS only) ───
HOST_ID=""
if [[ "$IS_MAC" == true ]]; then
  echo "Checking for available dedicated host..."
  HOST_ID=$(aws ec2 describe-hosts \
    --region "$REGION" \
    --filter \
      "Name=state,Values=available" \
      "Name=instance-type,Values=$INSTANCE_TYPE" \
      "Name=tag:project,Values=agent-army" \
      "Name=availability-zone,Values=$AZ" \
    --query 'Hosts[?length(Instances)==`0`] | [0].HostId' \
    --output text 2>/dev/null || echo "None")

  if [[ -z "$HOST_ID" || "$HOST_ID" == "None" ]]; then
    echo "Allocating dedicated host for $INSTANCE_TYPE..."
    echo "WARNING: 24-hour minimum billing at ~\$$COST/hr (~\$$(echo "$COST * 24" | bc)/day)"
    HOST_ID=$(aws ec2 allocate-hosts \
      --region "$REGION" \
      --instance-type "$INSTANCE_TYPE" \
      --availability-zone "$AZ" \
      --quantity 1 \
      --tag-specifications "ResourceType=dedicated-host,Tags=[{Key=project,Value=agent-army}]" \
      --query 'HostIds[0]' \
      --output text)
    echo "Dedicated host allocated: $HOST_ID"
  else
    echo "Reusing existing dedicated host: $HOST_ID"
  fi
fi

# ─── Generate Tailscale ephemeral auth key ───
echo "Generating Tailscale auth key..."
TS_API_KEY=$(op read "$OP_TAILSCALE_API_KEY")
TS_AUTH_KEY=$(curl -s -X POST "https://api.tailscale.com/api/v2/tailnet/-/keys" \
  -H "Authorization: Bearer $TS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "capabilities": {
      "devices": {
        "create": {
          "reusable": false,
          "ephemeral": true,
          "preauthorized": true,
          "tags": ["tag:agent"]
        }
      }
    },
    "expirySeconds": 3600
  }' | jq -r '.key')

if [[ -z "$TS_AUTH_KEY" || "$TS_AUTH_KEY" == "null" ]]; then
  echo "ERROR: Failed to generate Tailscale auth key"
  exit 1
fi
echo "Tailscale auth key generated (ephemeral, expires in 1hr)"

# ─── Build user-data script ───
if [[ "$IS_MAC" == true ]]; then
  BOOTSTRAP_CONTENT=$(cat "$PROJECT_DIR/bootstrap-mac.sh")
elif [[ "${USING_BAKED_AMI:-false}" == true ]]; then
  BOOTSTRAP_CONTENT="echo 'Pre-baked AMI — skipping bootstrap.'"
else
  BOOTSTRAP_CONTENT=$(cat "$PROJECT_DIR/bootstrap.sh")
fi
POST_BOOTSTRAP_CONTENT=$(cat "$PROJECT_DIR/scripts/post-bootstrap.sh")

if [[ "$IS_MAC" == true ]]; then
  USER_DATA=$(cat <<USERDATA
#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/bootstrap.log) 2>&1

# Env vars for bootstrap and post-bootstrap
export TS_AUTH_KEY="$TS_AUTH_KEY"
export INSTANCE_NAME="$INSTANCE_NAME"
export REGION="$REGION"
export OP_GITHUB_TOKEN="$OP_GITHUB_TOKEN"
export AGENT_USER="$AGENT_USER"
export USER_HOME="$USER_HOME"

# ── Run bootstrap (installs all dev tools via Homebrew) ──
$BOOTSTRAP_CONTENT

# ── Post-bootstrap (Tailscale, secrets, git) ──
$POST_BOOTSTRAP_CONTENT
USERDATA
)
else
  USER_DATA=$(cat <<USERDATA
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Env vars for bootstrap and post-bootstrap
export TS_AUTH_KEY="$TS_AUTH_KEY"
export INSTANCE_NAME="$INSTANCE_NAME"
export REGION="$REGION"
export OP_GITHUB_TOKEN="$OP_GITHUB_TOKEN"
export AGENT_USER="$AGENT_USER"
export USER_HOME="$USER_HOME"

# ── Run bootstrap (installs all dev tools) ──
$BOOTSTRAP_CONTENT

# ── Post-bootstrap (Tailscale, secrets, git) ──
$POST_BOOTSTRAP_CONTENT
USERDATA
)
fi

# ─── Find or create key pair ───
KEY_NAME="agent-army-$REGION"
if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" &>/dev/null; then
  # Check for existing keys with other names
  EXISTING_KEY=$(aws ec2 describe-key-pairs --region "$REGION" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "None")
  if [[ -n "$EXISTING_KEY" && "$EXISTING_KEY" != "None" ]]; then
    KEY_NAME="$EXISTING_KEY"
    echo "Using existing key pair: $KEY_NAME"
  else
    echo "WARNING: No key pair found in $REGION. Launching without key pair (SSH via Tailscale only)."
    KEY_NAME=""
  fi
else
  echo "Using key pair: $KEY_NAME"
fi
KEY_OPT=""
if [[ -n "$KEY_NAME" ]]; then
  KEY_OPT="--key-name $KEY_NAME"
fi

# ─── Launch instance ───
echo "Launching EC2 instance..."
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=project,Value=agent-army},{Key=os,Value=$OS_TAG}]"

if [[ "$IS_MAC" == true ]]; then
  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" \
    --placement "HostId=$HOST_ID" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
    --tag-specifications "$TAGS" \
    --user-data "$USER_DATA" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":120,"VolumeType":"gp3"}}]' \
    $KEY_OPT \
    --query 'Instances[0].InstanceId' \
    --output text)
else
  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
    --tag-specifications "$TAGS" \
    --user-data "$USER_DATA" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
    --query 'Instances[0].InstanceId' \
    --output text)
fi

echo "Instance ID: $INSTANCE_ID"

# ─── Wait for instance to be running ───
echo "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "Instance is running."

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text 2>/dev/null || echo "")
echo "Public IP: $PUBLIC_IP"

# ─── Wait for instance status checks (macOS takes 6-20 min to boot) ───
echo "Waiting for instance status checks to pass..."
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "Status checks passed."

# ─── Wait for Tailscale to connect ───
if [[ "$IS_MAC" == true ]]; then
  WAIT_ITERATIONS=120
  WAIT_MSG="macOS bootstrap + Tailscale can take 10-20 min after status checks"
elif [[ "${USING_BAKED_AMI:-false}" == true ]]; then
  WAIT_ITERATIONS=18
  WAIT_MSG="pre-baked AMI — should be ready in ~30 sec"
else
  WAIT_ITERATIONS=60
  WAIT_MSG="bootstrap + Tailscale takes 3-5 min"
fi

echo "Waiting for $INSTANCE_NAME to appear on Tailscale ($WAIT_MSG)..."
for i in $(seq 1 $WAIT_ITERATIONS); do
  if tailscale status 2>/dev/null | grep "$INSTANCE_NAME" | grep -q "active"; then
    echo ""
    echo "============================================"
    echo "  $INSTANCE_NAME is ready!"
    echo "============================================"
    echo "  Instance:  $INSTANCE_ID"
    echo "  Type:      $INSTANCE_TYPE"
    echo "  Cost:      ~\$$COST/hr"
    echo "  SSH:       ssh $AGENT_USER@$INSTANCE_NAME"
    echo "============================================"
    exit 0
  fi
  printf "."
  sleep 10
done

echo ""
echo "WARNING: $INSTANCE_NAME did not appear on Tailscale within expected time."
echo "Instance $INSTANCE_ID is running — bootstrap may still be in progress."
echo "Check: tailscale status"
if [[ -n "$PUBLIC_IP" ]]; then
  echo "Fallback SSH: ssh -i ~/.ssh/agent-mac-key.pem $AGENT_USER@$PUBLIC_IP"
fi
