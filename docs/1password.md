# 1Password Secret Management

> All secrets are stored in 1Password and accessed via service accounts. One token per agent — everything else is pulled at runtime.

## Overview

Instead of managing secrets differently across environments (AWS Secrets Manager for EC2, `.env` files for laptops), we use 1Password everywhere. The 1Password CLI (`op`) injects secrets at runtime without writing them to disk.

```
┌──────────────────────┐
│    1Password Vault    │
│    "Agent Army"       │
│                       │
│  github-token         │
│  tailscale-api-key    │
│  linear-api-key       │
│  slack-bot-token      │
└──────────┬────────────┘
           │
           │  op read / op run
           │
    ┌──────┴──────────────────────────────┐
    │                                      │
    ▼                                      ▼
┌──────────────┐                ┌──────────────────┐
│  EC2 Agent    │                │  Personal Device  │
│               │                │                   │
│  SA token     │                │  SA token or      │
│  via user-    │                │  biometric auth   │
│  data         │                │                   │
│               │                │                   │
│  op run →     │                │  op run →          │
│  agent-       │                │  agent-            │
│  wrapper      │                │  wrapper           │
└──────────────┘                └──────────────────┘
```

## Vault Setup

Create a shared vault in 1Password called **"Agent Army"**. Add these items:

| Item Name | Type | Fields |
|---|---|---|
| `anthropic-key` | API Credential | `credential` = your Anthropic API key |
| `github-token` | API Credential | `credential` = GitHub PAT with `repo` scope |
| `tailscale-api-key` | API Credential | `credential` = Tailscale API key |
| `linear-api-key` | API Credential | `credential` = Linear API key |
| `slack-bot-token` | API Credential | `credential` = Slack bot OAuth token |

### Secret references

Each secret is referenced with a URI:

```
op://Agent Army/anthropic-key/credential
op://Agent Army/github-token/credential
op://Agent Army/tailscale-api-key/credential
op://Agent Army/linear-api-key/credential
op://Agent Army/slack-bot-token/credential
```

These references are safe to commit to git — they contain no actual secret values.

## Service Accounts

Service accounts authenticate the 1Password CLI without requiring biometrics or interactive login. Each agent environment gets its own service account.

### Create a service account

#### Via 1password.com (recommended)

1. Sign in at **1password.com**
2. Go to **Developer → Directory**
3. Click **Create a Service Account**
4. Name: `agent-army-ec2` (or `agent-army-worker`, etc.)
5. Grant access to the **"Agent Army"** vault
6. Permissions: **Read Items** (agents only need to read secrets)
7. Click **Create**
8. **Save the token immediately** — it is only shown once

#### Via CLI

```bash
op service-account create "agent-army-ec2" \
  --vault "Agent Army" \
  --read-items
```

The token looks like: `ops_xxxxxxxxxxxxxxxxxxxxxxxx`

### Recommended service accounts

| Name | Used by | Vault access | Permissions |
|---|---|---|---|
| `agent-army-ec2` | EC2 agent instances | Agent Army | Read |
| `agent-army-worker` | Personal device workers | Agent Army | Read |
| `agent-army-app` | Next.js app (Vercel) | Agent Army | Read |

Using separate accounts per environment means revoking one doesn't break the others.

### Important limitations

- **Token shown once**: save it in 1Password itself (in a separate admin vault)
- **Vault access is immutable**: if you need different vault access, create a new service account
- **Cannot access personal/private vaults**: only shared vaults you explicitly grant
- **Rate limited**: read secrets once at startup, don't poll in a loop
- **Up to 100 service accounts** per 1Password account

## Using the CLI

### Install

```bash
# macOS
brew install 1password-cli

# Ubuntu/Debian (ARM64 — for EC2 Graviton instances)
curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
  gpg --dearmor -o /usr/share/keyrings/1password.gpg
echo "deb [arch=arm64 signed-by=/usr/share/keyrings/1password.gpg] \
  https://downloads.1password.com/linux/debian/arm64 stable main" | \
  tee /etc/apt/sources.list.d/1password.list
apt-get update && apt-get install -y 1password-cli

# Verify
op --version
```

### Authenticate

```bash
# For service accounts (agents, CI, automation):
export OP_SERVICE_ACCOUNT_TOKEN="ops_xxxxxxxx"

# For personal use (interactive, biometric):
op signin
```

### Read a secret

```bash
# Print to stdout
op read "op://Agent Army/anthropic-key/credential"

# Store in a variable (never written to disk)
GITHUB_TOKEN=$(op read "op://Agent Army/github-token/credential")

# Write to a file (if needed)
op read "op://Agent Army/github-token/credential" --out-file /tmp/token.txt
```

### Inject secrets into a process

Create an env template file (safe to commit):

```bash
# agent.env
ANTHROPIC_API_KEY="op://Agent Army/anthropic-key/credential"
GITHUB_TOKEN="op://Agent Army/github-token/credential"
```

Run a command with secrets injected:

```bash
# Resolves all op:// references, passes real values as env vars
op run --env-file agent.env -- agent --task-id 42

# Or inline:
op run --env ANTHROPIC_API_KEY="op://Agent Army/anthropic-key/credential" -- claude
```

`op run` resolves every `op://` reference and passes real values as environment variables to the child process. Secrets never touch disk.

### Inject into config files

For config files that need secrets:

```yaml
# config.yml.tpl (safe to commit)
database:
  url: op://Agent Army/database-url/credential
api:
  key: op://Agent Army/anthropic-key/credential
```

```bash
# Resolve and write the real config
op inject --in-file config.yml.tpl --out-file config.yml
```

## EC2 Agent Usage

The service account token is the **only secret** passed to EC2 instances. Everything else is pulled from 1Password at runtime.

### How the token reaches the instance

The 1Password service account token is stored in AWS Systems Manager Parameter Store as a `SecureString`. The bootstrap script reads it via the instance's IAM role — **not** via user-data, which is readable by any process on the instance. See [security.md](security.md#1password-sa-token-via-ssm) for why user-data is not used.

```bash
# In the startup script (after bootstrap.sh):
# Pull 1Password SA token from SSM (not user-data)
export OP_SERVICE_ACCOUNT_TOKEN=$(aws ssm get-parameter \
  --name "/agent-army/op-sa-token" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region us-west-1)

# Configure git (secret resolved at runtime, not stored)
GITHUB_TOKEN=$(op read "op://Agent Army/github-token/credential")
git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

# Authenticate GitHub CLI
op read "op://Agent Army/github-token/credential" | gh auth login --with-token

# Start the agent wrapper with all secrets injected
op run --env-file /opt/agent/agent.env -- agent --task-id "${AGENT_ID}"
```

### agent.env template (deployed to EC2)

```bash
# /opt/agent/agent.env
# Safe to include in AMI or user-data — no real secrets
ANTHROPIC_API_KEY="op://Agent Army/anthropic-key/credential"
GITHUB_TOKEN="op://Agent Army/github-token/credential"
```

## Personal Device Usage

On personal devices, you can use either the service account token or your personal 1Password login with biometric auth.

### Option A: Service account (recommended for worker daemon)

```bash
# In worker's .env (only one real secret)
OP_SERVICE_ACCOUNT_TOKEN=ops_xxxxxxxx

# Worker starts agent with op run:
op run --env-file agent.env -- agent --task-id 42
```

### Option B: Personal login (for manual use)

```bash
# Sign in with biometrics (macOS Touch ID, etc.)
eval $(op signin)

# Now op commands work with your full account access
op run --env-file agent.env -- agent --task "fix the bug"
```

## App (Vercel) Usage

The Next.js app on Vercel uses a service account to read secrets for API integrations (Linear, Slack, Tailscale).

```typescript
// lib/secrets.ts
import { exec } from 'child_process';

// On Vercel, OP_SERVICE_ACCOUNT_TOKEN is set as an environment variable
// op CLI is installed in the build step or as a dependency

async function getSecret(ref: string): Promise<string> {
  return new Promise((resolve, reject) => {
    exec(`op read "${ref}"`, (err, stdout) => {
      if (err) reject(err);
      else resolve(stdout.trim());
    });
  });
}

// Usage:
const linearKey = await getSecret('op://Agent Army/linear-api-key/credential');
const slackToken = await getSecret('op://Agent Army/slack-bot-token/credential');
```

Alternatively, for Vercel specifically, you may prefer to set secrets directly as Vercel environment variables (pulled from 1Password manually or via the 1Password Vercel integration). The service account approach is most valuable for EC2 and personal devices.

## Secret Rotation

When you need to rotate a secret:

1. Update the value in 1Password (via app or CLI)
2. **EC2 agents**: new instances automatically get the new value. Running instances need restart.
3. **Personal devices**: restart the worker daemon — `op run` pulls fresh values on each invocation.
4. **No code changes needed** — secret references (`op://...`) stay the same.

```bash
# Update a secret via CLI
op item edit "anthropic-key" --vault "Agent Army" "credential=sk-ant-new-key-here"
```

## Compared to AWS Secrets Manager

| | 1Password | AWS Secrets Manager |
|---|---|---|
| Works on EC2 | Yes (service account token) | Yes (IAM instance role) |
| Works on personal devices | Yes (same tool) | No (needs IAM credentials) |
| Works on Vercel | Yes (service account) | Yes (but needs AWS SDK) |
| One tool everywhere | Yes | No |
| Secret rotation UI | 1Password app | AWS Console |
| `op run` (inject without disk) | Yes | No (must export manually) |
| Cost | Already paying for 1Password | $0.40/secret/month + API calls |
| Team sharing | Built-in vault sharing | IAM policy management |
