#!/bin/bash
# Launch an EC2 instance with bootstrap, Tailscale, and 1Password configured.
# Usage: ./scripts/launch.sh --name agent-1 [--type t3.xlarge]
set -euo pipefail

# Load 1Password secret paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../secrets.env"

# Defaults
INSTANCE_TYPE="t3.xlarge"
INSTANCE_NAME=""
REGION="us-west-1"

# Infrastructure IDs (already provisioned)
SUBNET_ID="subnet-07c07f3137b79ed68"
SG_ID="sg-072b72ae3cee797a7"
INSTANCE_PROFILE="agent-instance-role"

# Hourly costs for display
get_cost() {
  case "$1" in
    t3.medium)   echo "0.042" ;;
    t3.large)    echo "0.083" ;;
    t3.xlarge)   echo "0.166" ;;
    c7i.2xlarge) echo "0.357" ;;
    *)           echo "unknown" ;;
  esac
}

# ─── Parse args ───
while [[ $# -gt 0 ]]; do
  case $1 in
    --name) INSTANCE_NAME="$2"; shift 2 ;;
    --type) INSTANCE_TYPE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_NAME" ]]; then
  echo "Usage: ./scripts/launch.sh --name <name> [--type <instance-type>]"
  echo ""
  echo "Instance types:"
  echo "  t3.medium    (2 vCPU,  4 GB) - \$0.042/hr"
  echo "  t3.large     (2 vCPU,  8 GB) - \$0.083/hr"
  echo "  t3.xlarge    (4 vCPU, 16 GB) - \$0.166/hr  [default]"
  echo "  c7i.2xlarge  (8 vCPU, 16 GB) - \$0.357/hr"
  exit 1
fi

COST="$(get_cost "$INSTANCE_TYPE")"
echo "=== Launching $INSTANCE_NAME ($INSTANCE_TYPE, ~\$$COST/hr) ==="

# ─── Find latest Ubuntu 22.04 amd64 AMI ───
echo "Finding latest Ubuntu amd64 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
echo "AMI: $AMI_ID"

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
# Compose bootstrap.sh + post-bootstrap.sh into a single user-data script
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP_CONTENT=$(cat "$PROJECT_DIR/bootstrap.sh")
POST_BOOTSTRAP_CONTENT=$(cat "$PROJECT_DIR/scripts/post-bootstrap.sh")

USER_DATA=$(cat <<USERDATA
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Env vars for post-bootstrap
export TS_AUTH_KEY="$TS_AUTH_KEY"
export INSTANCE_NAME="$INSTANCE_NAME"
export REGION="$REGION"
export OP_GITHUB_TOKEN="$OP_GITHUB_TOKEN"

# ── Run bootstrap (installs all dev tools) ──
$BOOTSTRAP_CONTENT

# ── Post-bootstrap (Tailscale, secrets, git) ──
$POST_BOOTSTRAP_CONTENT
USERDATA
)

# ─── Launch instance ───
echo "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=project,Value=agent-army}]" \
  --user-data "$USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance ID: $INSTANCE_ID"

# ─── Wait for instance to be running ───
echo "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "Instance is running."

# ─── Wait for Tailscale to connect ───
echo "Waiting for $INSTANCE_NAME to appear on Tailscale (this takes 3-5 min for bootstrap)..."
for i in $(seq 1 60); do
  if tailscale status 2>/dev/null | grep "$INSTANCE_NAME" | grep -q "active"; then
    echo ""
    echo "============================================"
    echo "  $INSTANCE_NAME is ready!"
    echo "============================================"
    echo "  Instance:  $INSTANCE_ID"
    echo "  Type:      $INSTANCE_TYPE"
    echo "  Cost:      ~\$$COST/hr"
    echo "  SSH:       ssh $INSTANCE_NAME"
    echo "============================================"
    exit 0
  fi
  printf "."
  sleep 10
done

echo ""
echo "WARNING: $INSTANCE_NAME did not appear on Tailscale within 10 minutes."
echo "Instance $INSTANCE_ID is running — bootstrap may still be in progress."
echo "Check: tailscale status"
echo "Or SSH via instance IP once Tailscale connects."
