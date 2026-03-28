# Symlink claude config + dotfiles
setup:
    ./setup.sh

# Start local Supabase (Postgres + services in Docker)
supabase-start:
    supabase start

# Stop local Supabase
supabase-stop:
    supabase stop

# Show Supabase service status and URLs
supabase-status:
    supabase status

# Inject secrets from 1Password → ~/.env-secrets.sh
secrets:
    ./secrets.sh

# SSH options for ephemeral EC2 instances
ssh_opts := "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
skill_dir := "~/.claude/skills/ec2-compute"

# Launch an EC2 instance: just launch <name> [type]
launch name type="t3.medium":
    {{skill_dir}}/scripts/launch.sh --name {{name}} --type {{type}}

# Terminate an instance: just terminate <name>
terminate name:
    {{skill_dir}}/scripts/terminate.sh --name {{name}}

# Terminate all instances
terminate-all:
    {{skill_dir}}/scripts/terminate.sh --all

# Show status of all instances
status:
    {{skill_dir}}/scripts/status.sh

# SSH into an instance: just ssh <name> [command]
ssh name *cmd:
    ssh {{ssh_opts}} ubuntu@{{name}} {{cmd}}

# Launch a macOS EC2 instance: just launch-mac <name> [type]
launch-mac name type="mac2.metal":
    {{skill_dir}}/scripts/launch.sh --name {{name}} --type {{type}}

# SSH into a Mac instance: just ssh-mac <name> [command]
ssh-mac name *cmd:
    ssh {{ssh_opts}} ec2-user@{{name}} {{cmd}}

# Release idle Mac dedicated hosts
release-mac-host:
    {{skill_dir}}/scripts/release-mac-host.sh

# Deploy IAM policies (resolves ACCOUNT_ID at deploy time)
deploy-iam:
    #!/usr/bin/env bash
    set -euo pipefail
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    echo "Deploying IAM policies for account $ACCOUNT_ID..."
    sed "s/ACCOUNT_ID/$ACCOUNT_ID/g" iam/agent-instance-role-policy.json | \
      aws iam put-role-policy --role-name agent-instance-role \
        --policy-name agent-instance-policy --policy-document file:///dev/stdin
    echo "  ✓ agent-instance-role"
    sed "s/ACCOUNT_ID/$ACCOUNT_ID/g" iam/app-role-policy.json | \
      aws iam put-role-policy --role-name app-role \
        --policy-name app-role-policy --policy-document file:///dev/stdin
    echo "  ✓ app-role"
    echo "Done."

