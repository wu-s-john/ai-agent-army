# AWS Infrastructure

> EC2 instances, networking, storage, secrets, and macOS dedicated hosts. Region: us-west-1.

## VPC & Networking

```
┌─────────────────────────────────────────────────┐
│                  VPC (10.0.0.0/16)              │
│                                                  │
│  ┌──────────────────────────────────────┐       │
│  │      Private Subnet (10.0.1.0/24)    │       │
│  │                                       │       │
│  │  ┌─────────┐  ┌─────────┐           │       │
│  │  │ agent-1 │  │ agent-2 │  ...      │       │
│  │  └────┬────┘  └────┬────┘           │       │
│  │       │             │                │       │
│  │       ▼             ▼                │       │
│  │  ┌──────────────────────┐           │       │
│  │  │    NAT Gateway       │           │       │
│  │  └──────────┬───────────┘           │       │
│  └─────────────┼────────────────────────┘       │
│                │                                 │
│                ▼                                 │
│  ┌──────────────────────┐                       │
│  │   Internet Gateway    │                       │
│  └──────────────────────┘                       │
└─────────────────────────────────────────────────┘
```

- **Private subnet only** — no public IPs on instances
- **NAT Gateway** — outbound internet (GitHub, npm, APIs, Tailscale)
- **No inbound** — all access via Tailscale mesh, not public internet

### Security groups

```
agent-sg:
  Inbound:  (none — all access via Tailscale)
  Outbound: 0.0.0.0/0 : all ports  (NAT Gateway handles routing)
```

Agents don't need inbound rules because Tailscale handles connectivity via its encrypted mesh tunnel. The security group only needs to allow outbound traffic.

## Instance Types

| Profile | Instance Type | vCPUs | RAM | Use Case | Spot? |
|---|---|---|---|---|---|
| `code-small` | t4g.medium | 2 | 4 GB | Quick fixes, reviews | Yes |
| `code-large` | t4g.xlarge | 4 | 16 GB | Standard coding tasks | Yes |
| `bench` | c7g.2xlarge | 8 | 16 GB | Benchmarks, performance testing | On-demand |
| `research` | t4g.large | 2 | 8 GB | Long-running research (low CPU) | Yes |
| `mac-m1` | mac2.metal | 8 | 16 GB | macOS/iOS development | On-demand* |
| `mac-m2pro` | mac2-m2pro.metal | 12 | 32 GB | Heavy macOS builds | On-demand* |

*macOS instances require dedicated hosts with 24-hour minimum allocation.

These types are constrained in the IAM policy (`iam/app-role-policy.json`) — the app cannot launch other instance types.

## Spot vs On-Demand Strategy

| Use | Strategy | Why |
|---|---|---|
| Code tasks | **Spot** preferred | Cost savings (60-70%), task is retryable |
| Benchmarks | **On-demand** | Consistent performance needed, no interruptions |
| Research | **Spot** | Long-running but checkpoint-friendly |
| macOS | **On-demand** | Spot not available for dedicated hosts |

### Spot interruption handling

Each EC2 agent runs a **spot monitor** alongside the agent wrapper. It polls the instance metadata service for interruption notices:

```bash
#!/bin/bash
# spot-monitor.sh — runs alongside the agent wrapper
WRAPPER_PID=$1

while true; do
  # AWS provides 2-minute warning via instance metadata
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    http://169.254.169.254/latest/meta-data/spot/instance-action)

  if [ "$HTTP_CODE" -eq 200 ]; then
    echo "Spot interruption detected — sending SIGTERM to wrapper"
    kill -TERM "$WRAPPER_PID"
    break
  fi
  sleep 5
done
```

When SIGTERM reaches the agent wrapper, it triggers graceful shutdown:

```typescript
// Inside the agent wrapper (see architecture.md for full wrapper design):
process.on('SIGTERM', async () => {
  // Inject urgent message into Claude Code session
  await session.sendMessage(
    'URGENT: This instance is being terminated in 2 minutes. ' +
    'Commit all work-in-progress NOW. ' +
    'Run: git add -A && git commit -m "WIP: spot interruption" && git push'
  );

  // Wait up to 90s for git push
  await session.waitForCompletion({ timeout: 90_000 });

  // Report to app
  await fetch(`${APP_URL}/api/agent/error`, {
    method: 'POST',
    body: JSON.stringify({
      taskId,
      error: 'Spot interruption — WIP committed and pushed',
      retriable: true,
    }),
  });

  process.exit(0);
});
```

The app then re-provisions on-demand:

```typescript
async function handleSpotInterruption(taskId: number) {
  const task = await db.tasks.find(taskId);
  await db.resources.update(task.resource_id, { status: 'interrupted' });

  // Re-provision as on-demand (no more spot for this task)
  await spawnOnDemand(task.id);
}
```

## AMI Strategy

**Stock Ubuntu + bootstrap** (no custom AMI):

- Use latest Ubuntu 22.04 ARM64 AMI (`ami-*` for Graviton)
- `bootstrap.sh` installs everything at boot
- Bootstrap takes ~3-5 minutes
- Simpler than maintaining custom AMIs

**Future optimization**: bake a custom AMI with tools pre-installed to reduce boot time to ~30 seconds. Not needed initially.

### Finding the latest Ubuntu ARM64 AMI

```bash
aws ec2 describe-images \
  --region us-west-1 \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*" \
    "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text
```

## Bootstrap Script

The existing `bootstrap.sh` in the repo root installs:

| Category | What |
|---|---|
| Build tools | git, curl, build-essential, cmake, clang |
| Languages | Rust, Node.js 22, Python 3 |
| AI | Claude Code CLI |
| Editor | Zed |
| Terminal | Zellij, Zsh, Starship prompt |
| CLI tools | ripgrep, fd, bat, fzf, eza, zoxide, dust |

After bootstrap, a startup script (not yet written) handles:

1. **Pull secrets** from AWS Secrets Manager
2. **Install Tailscale** and join tailnet with ephemeral key
3. **Clone repo** using GitHub token (HTTPS)
4. **Configure git** for the agent
5. **Start Zellij** session with agent layout
6. **Launch Claude Code** with task context and system prompt
7. **Call** POST `/api/agent/ready`

### Secrets injection

```bash
# Startup script (runs after bootstrap)
ANTHROPIC_KEY=$(aws secretsmanager get-secret-value \
  --secret-id agent/anthropic-key --query SecretString --output text)

GITHUB_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id agent/github-token --query SecretString --output text)

TAILSCALE_KEY=$(aws secretsmanager get-secret-value \
  --secret-id agent/tailscale-key-${AGENT_ID} --query SecretString --output text)

export ANTHROPIC_API_KEY="${ANTHROPIC_KEY}"

# Configure git with GitHub token
git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

# GitHub CLI auth
echo "${GITHUB_TOKEN}" | gh auth login --with-token
```

## EBS Storage

### Root volume

- **Size**: 30 GB (gp3)
- **IOPS**: 3000 (default)
- **Throughput**: 125 MB/s (default)
- Sufficient for OS + tools + repo

### Data volume (optional)

For tasks that need extra storage (large repos, datasets):

- **Size**: 100-500 GB (gp3)
- **Mount**: `/data`
- Attached at launch, formatted and mounted in bootstrap

### Snapshots

Not needed for ephemeral agents. If we ever need persistent workspace state, snapshots can be taken before termination.

## Secrets Manager

All secrets live under the `agent/*` prefix:

| Secret | Purpose |
|---|---|
| `agent/anthropic-key` | Claude API key |
| `agent/github-token` | GitHub PAT (repo scope) — for git push, gh CLI, GitHub API |
| `agent/tailscale-api-key` | Tailscale API key (for generating auth keys) |
| `agent/tailscale-key-{id}` | Per-agent ephemeral auth key (created by app, short-lived) |
| `agent/linear-api-key` | Linear API key (used by app, not agents) |
| `agent/slack-bot-token` | Slack bot token (used by app, not agents) |

IAM policy restricts agent instances to only read `agent/anthropic-key` and `agent/github-token` — they cannot access Tailscale API keys, Linear keys, or Slack tokens.

## IAM Roles

Two roles, defined in the `iam/` directory:

### app-role

The role assumed by the app (Vercel serverless functions or VPS). Can:

- Launch/terminate EC2 instances (constrained to allowed types)
- Read all secrets under `agent/*`
- Manage spot requests
- Allocate/release dedicated hosts
- Create EBS snapshots
- Write CloudWatch metrics and logs
- Pass `agent-instance-role` to EC2 instances

See `iam/app-role-policy.json` for full policy.

### agent-instance-role

The role assumed by EC2 agent instances. Minimal permissions:

- Read `agent/anthropic-key` and `agent/github-token` from Secrets Manager
- Write to CloudWatch Logs (`/agent-army/instances/*`)
- Describe own EC2 tags

See `iam/agent-instance-role-policy.json` for full policy.

## macOS Dedicated Hosts

macOS on EC2 requires dedicated hosts with a **24-hour minimum allocation**.

### Allocation

```typescript
const { HostIds } = await ec2.allocateHosts({
  AvailabilityZone: 'us-west-1a',
  InstanceType: 'mac2.metal',  // or mac2-m2pro.metal
  Quantity: 1,
  AutoPlacement: 'on',
  TagSpecifications: [{
    ResourceType: 'dedicated-host',
    Tags: [{ Key: 'Name', Value: `mac-host-${Date.now()}` }],
  }],
});
```

### Instance launch on dedicated host

```typescript
await ec2.runInstances({
  ImageId: MAC_AMI_ID,
  InstanceType: 'mac2.metal',
  MinCount: 1,
  MaxCount: 1,
  Placement: { HostId: hostId },
  // ... other params
});
```

### Release

Hosts can only be released after 24 hours:

```typescript
// Check if 24 hours have passed since allocation
const host = await ec2.describeHosts({ HostIds: [hostId] });
const allocatedAt = host.Hosts[0].AllocationTime;
const hoursElapsed = (Date.now() - allocatedAt.getTime()) / 3600000;

if (hoursElapsed >= 24) {
  await ec2.releaseHosts({ HostIds: [hostId] });
}
```

### Cost optimization

Since you're paying for 24 hours regardless, the app should:
1. Queue macOS tasks to reuse an active dedicated host
2. Track host allocation times
3. Alert via Slack when a host is approaching 24h with no active tasks
4. Batch macOS work when possible

## Region

**us-west-1** (N. California) — locked in IAM policy conditions. All EC2, Secrets Manager, and CloudWatch operations are restricted to this region.

## Auto-Cleanup

### Health check

```typescript
// Runs every 5 minutes
async function healthCheck() {
  const runningResources = await db.resources.findByStatus('running');

  for (const resource of runningResources) {
    if (resource.type === 'ec2') {
      const instance = await ec2.describeInstanceStatus({
        InstanceIds: [resource.instance_id],
      });

      if (!instance.InstanceStatuses?.length) {
        // Instance is gone
        await markResourceDead(resource);
      }
    }
  }
}
```

### Stale instance termination

```typescript
// Terminate instances running longer than max duration (default: 4 hours)
async function terminateStaleInstances() {
  const stale = await db.resources.findStale(MAX_DURATION_HOURS);

  for (const resource of stale) {
    await slack.chat.postMessage({
      channel: ALERTS_CHANNEL,
      text: `:warning: Terminating stale instance ${resource.name} (running ${resource.hoursRunning}h)`,
    });

    await ec2.terminateInstances({ InstanceIds: [resource.instance_id] });
    await db.resources.update(resource.id, { status: 'terminated' });
  }
}
```

### Billing alarms

CloudWatch billing alarm as a safety net:

```typescript
await cloudwatch.putMetricAlarm({
  AlarmName: 'agent-army-daily-spend',
  MetricName: 'EstimatedCharges',
  Namespace: 'AWS/Billing',
  Statistic: 'Maximum',
  Period: 86400,
  EvaluationPeriods: 1,
  Threshold: 100, // $100/day
  ComparisonOperator: 'GreaterThanThreshold',
  AlarmActions: [SNS_TOPIC_ARN],
});
```
