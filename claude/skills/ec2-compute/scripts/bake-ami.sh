#!/bin/bash
# Bake a custom Linux AMI with all dev tools pre-installed.
# Usage: ./scripts/bake-ami.sh [--region eu-west-1]
#
# Creates an AMI from a fully bootstrapped Ubuntu instance so that
# future launches skip the 3-5 min bootstrap and boot in ~30 sec.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Defaults ───
REGION="eu-west-1"
INSTANCE_TYPE="t3.xlarge"
INSTANCE_PROFILE="agent-instance-role"

# ─── Parse args ───
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) REGION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ─── Infrastructure helpers (same as launch.sh) ───
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

# ─── Resolve infrastructure ───
SUBNET_ID="$(get_subnet "$REGION")"
SG_ID="$(get_sg "$REGION")"

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
  echo "ERROR: No infrastructure found for region $REGION"
  echo "Tag a subnet and security group with project=$PROJECT_TAG in $REGION"
  exit 1
fi

echo "=== Baking Linux AMI ==="
echo "Region: $REGION"

# ─── Find stock Ubuntu AMI ───
echo "Finding latest Ubuntu 22.04 amd64 AMI..."
STOCK_AMI=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
echo "Stock AMI: $STOCK_AMI"

# ─── Build user-data (bootstrap only, no post-bootstrap) ───
BOOTSTRAP_CONTENT=$(cat "$PROJECT_DIR/bootstrap.sh")
USER_DATA=$(cat <<USERDATA
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

$BOOTSTRAP_CONTENT
USERDATA
)

# ─── Find or reuse key pair ───
KEY_NAME="agent-army-$REGION"
KEY_OPT=""
if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" &>/dev/null; then
  KEY_OPT="--key-name $KEY_NAME"
fi

# ─── Launch temp instance ───
echo "Launching temporary instance for baking..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$STOCK_AMI" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ami-bake-temp},{Key=project,Value=$PROJECT_TAG}]" \
  --user-data "$USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  $KEY_OPT \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Temp instance: $INSTANCE_ID"

# ─── Cleanup on failure ───
cleanup() {
  echo ""
  echo "Cleaning up: terminating $INSTANCE_ID..."
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null 2>&1 || true
}
trap cleanup ERR

# ─── Wait for instance to start ───
echo "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "Instance is running."

# ─── Wait for status checks ───
echo "Waiting for status checks..."
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "Status checks passed."

# ─── Poll console output for bootstrap completion ───
echo "Waiting for bootstrap to complete (polling console output)..."
MAX_POLLS=30  # 30 × 30s = 15 min timeout
for i in $(seq 1 $MAX_POLLS); do
  OUTPUT=$(aws ec2 get-console-output \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Output' \
    --output text 2>/dev/null || echo "")

  if echo "$OUTPUT" | grep -q "Bootstrap complete!"; then
    echo ""
    echo "Bootstrap complete!"
    break
  fi

  if [[ $i -eq $MAX_POLLS ]]; then
    echo ""
    echo "ERROR: Bootstrap did not complete within 15 minutes."
    echo "Check console output: aws ec2 get-console-output --instance-id $INSTANCE_ID --region $REGION"
    cleanup
    exit 1
  fi

  printf "."
  sleep 30
done

# ─── Stop instance for filesystem consistency ───
echo "Stopping instance for clean snapshot..."
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "Instance stopped."

# ─── Create AMI ───
AMI_NAME="agent-army-linux-$(date +%Y%m%d-%H%M)"
BAKE_DATE="$(date +%Y-%m-%d)"

echo "Creating AMI: $AMI_NAME..."
AMI_ID=$(aws ec2 create-image \
  --instance-id "$INSTANCE_ID" \
  --name "$AMI_NAME" \
  --description "Pre-baked Ubuntu 22.04 with dev tools for agent-army" \
  --tag-specifications "ResourceType=image,Tags=[{Key=project,Value=$PROJECT_TAG},{Key=os,Value=linux},{Key=bake-date,Value=$BAKE_DATE},{Key=base-ami,Value=$STOCK_AMI}]" \
  --query 'ImageId' \
  --output text \
  --region "$REGION")

echo "AMI ID: $AMI_ID"
echo "Waiting for AMI to become available (this may take a few minutes)..."
aws ec2 wait image-available --image-ids "$AMI_ID" --region "$REGION"
echo "AMI is ready."

# ─── Terminate temp instance ───
echo "Terminating temp instance..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
trap - ERR

echo ""
echo "============================================"
echo "  AMI baked successfully!"
echo "============================================"
echo "  AMI ID:     $AMI_ID"
echo "  Name:       $AMI_NAME"
echo "  Region:     $REGION"
echo "  Base AMI:   $STOCK_AMI"
echo "  Bake date:  $BAKE_DATE"
echo ""
echo "  launch.sh will automatically use this AMI."
echo "  To force stock Ubuntu: launch.sh --name <name> --fresh"
echo "============================================"
