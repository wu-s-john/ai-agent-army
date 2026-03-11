# Security & Safety Rails

> API key management, network isolation, budget caps, kill switches, and audit logging.

## API Key Management

### EC2 agents

Secrets are stored in AWS Secrets Manager and pulled at boot time via IAM role:

```bash
# Agent instance role can only read these two secrets:
agent/anthropic-key      → Claude API key
agent/github-token       → GitHub PAT (repo scope)
```

Secrets are **never** passed in EC2 user-data (which is visible in instance metadata). The bootstrap script pulls them from Secrets Manager using the instance's IAM role.

### Personal devices

Secrets are stored locally in `.env`:

```bash
ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxx
GITHUB_TOKEN=ghp_xxxxxxxxxxxx
AGENT_WORKER_AUTH_TOKEN=wkr_xxxxxxxxxxxx
```

The `.env` file should be:
- Not committed to git (`.gitignore`)
- Readable only by the user (`chmod 600 .env`)

### GitHub token scope

A single GitHub Personal Access Token (or GitHub App installation token) with `repo` scope covers all operations:

| Operation | How |
|---|---|
| Clone repos | HTTPS + token in URL |
| Push branches | HTTPS + token in URL |
| Create PRs | `gh pr create` (GitHub CLI) |
| Read PR comments | GitHub webhooks → app |
| Comment on PRs | `gh pr comment` |
| GitHub API calls | `Authorization: Bearer` header |

See [github.md](github.md) for details.

## Generating Auth Secrets

Generate high-entropy tokens for API authentication:

```bash
openssl rand -hex 32   # → ADMIN_API_KEY
openssl rand -hex 32   # → WORKER_AUTH_TOKEN
```

Store each token in both Vercel env vars and the 1Password "Agent Army" vault.

| Env var | Where it's set | Purpose |
|---|---|---|
| `ADMIN_API_KEY` | Vercel env var | Dashboard API auth |
| `WORKER_AUTH_TOKEN` | Vercel env var + worker `.env` | Worker daemon auth |
| `LINEAR_WEBHOOK_SECRET` | Vercel env var | Linear webhook signature verification |
| `GITHUB_WEBHOOK_SECRET` | Vercel env var | GitHub webhook signature verification |
| `SLACK_SIGNING_SECRET` | Vercel env var | Slack request verification |

## Webhook Signature Verification

All inbound webhooks are verified using HMAC-SHA256 signatures before processing. Each provider sends a signature header that we validate against a shared secret.

### Linear

Linear sends a `linear-signature` header containing the HMAC-SHA256 hex digest of the request body.

```typescript
// app/api/webhooks/linear/route.ts
import crypto from 'crypto';

export async function POST(req: Request) {
  const body = await req.text();
  const signature = req.headers.get('linear-signature');

  if (!signature) {
    return Response.json({ error: 'missing signature' }, { status: 401 });
  }

  const expected = crypto
    .createHmac('sha256', process.env.LINEAR_WEBHOOK_SECRET!)
    .update(body)
    .digest('hex');

  if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) {
    return Response.json({ error: 'invalid signature' }, { status: 401 });
  }

  const payload = JSON.parse(body);
  // ... handle webhook
}
```

### GitHub

GitHub sends an `x-hub-signature-256` header with a `sha256=` prefix.

```typescript
// app/api/webhooks/github/route.ts
import crypto from 'crypto';

export async function POST(req: Request) {
  const body = await req.text();
  const signature = req.headers.get('x-hub-signature-256');

  if (!signature) {
    return Response.json({ error: 'missing signature' }, { status: 401 });
  }

  const expected = 'sha256=' + crypto
    .createHmac('sha256', process.env.GITHUB_WEBHOOK_SECRET!)
    .update(body)
    .digest('hex');

  if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) {
    return Response.json({ error: 'invalid signature' }, { status: 401 });
  }

  const payload = JSON.parse(body);
  // ... handle webhook
}
```

### Slack

Slack sends `x-slack-request-timestamp` and `x-slack-signature` headers. The signature covers `v0:{timestamp}:{body}`. Requests older than 5 minutes are rejected to prevent replay attacks.

```typescript
// app/api/slack/commands/route.ts (same pattern for events, interactions)
import crypto from 'crypto';

export async function POST(req: Request) {
  const body = await req.text();
  const timestamp = req.headers.get('x-slack-request-timestamp');
  const signature = req.headers.get('x-slack-signature');

  if (!timestamp || !signature) {
    return Response.json({ error: 'missing headers' }, { status: 401 });
  }

  // Reject requests older than 5 minutes (replay attack prevention)
  const age = Math.abs(Date.now() / 1000 - parseInt(timestamp));
  if (age > 300) {
    return Response.json({ error: 'request too old' }, { status: 401 });
  }

  const baseString = `v0:${timestamp}:${body}`;
  const expected = 'v0=' + crypto
    .createHmac('sha256', process.env.SLACK_SIGNING_SECRET!)
    .update(baseString)
    .digest('hex');

  if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) {
    return Response.json({ error: 'invalid signature' }, { status: 401 });
  }

  const payload = new URLSearchParams(body);
  // ... handle command
}
```

## Vercel Deployment Protection

The dashboard UI and all non-API routes are protected by Vercel's built-in Deployment Protection.

### Setup

1. Vercel dashboard → **Settings → Deployment Protection**
2. Enable **Standard Protection**
3. Set a password (shared with anyone who needs dashboard access)

### Bypassing for machine-to-machine routes

Webhook and API routes need to bypass Deployment Protection since they're called by external services, not browsers. Add to `vercel.json`:

```json
{
  "protectionBypass": [
    { "path": "/api/webhooks/linear", "scope": "automation" },
    { "path": "/api/webhooks/github", "scope": "automation" },
    { "path": "/api/agent/*", "scope": "automation" },
    { "path": "/api/worker/*", "scope": "automation" },
    { "path": "/api/slack/*", "scope": "automation" }
  ]
}
```

Bypassed routes are still secured by their own auth — webhook signature verification in route handlers, bearer tokens in middleware.

## API Endpoint Authentication

Every API endpoint is authenticated. The auth method varies by route type:

| Route | Auth method | Verified in |
|---|---|---|
| `/api/webhooks/linear` | Linear HMAC signature | Route handler |
| `/api/webhooks/github` | GitHub HMAC signature | Route handler |
| `/api/slack/*` | Slack signing secret | Route handler |
| `/api/agent/*` | Per-session callback token | Middleware + route handler |
| `/api/worker/*` | Worker auth token | Middleware |
| Dashboard UI + API | Vercel Deployment Protection | Vercel |

### Middleware

A Next.js middleware handles bearer token checks for agent and worker routes. Webhook and Slack routes pass through to their route handlers (which verify signatures).

```typescript
// middleware.ts
import { NextRequest, NextResponse } from 'next/server';

export const config = {
  matcher: '/api/:path*',
};

export async function middleware(req: NextRequest) {
  const path = req.nextUrl.pathname;

  // Webhooks + Slack: signature verified in route handlers, let through
  if (path.startsWith('/api/webhooks/') || path.startsWith('/api/slack/')) {
    return NextResponse.next();
  }

  // Agent callbacks: require bearer token (DB validation in route handler)
  if (path.startsWith('/api/agent/')) {
    const token = req.headers.get('authorization')?.replace('Bearer ', '');
    if (!token) {
      return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
    }
    // Token is present — route handler validates against claude_sessions.callback_token
    return NextResponse.next();
  }

  // Worker endpoints: require worker auth token
  if (path.startsWith('/api/worker/')) {
    const token = req.headers.get('authorization')?.replace('Bearer ', '');
    if (!token || token !== process.env.WORKER_AUTH_TOKEN) {
      return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
    }
    return NextResponse.next();
  }

  // All other /api/* routes: Vercel Deployment Protection handles auth
  return NextResponse.next();
}
```

## Per-Session Callback Tokens

Each agent session gets a unique callback token, generated when a task is assigned. This ensures agents can only report progress on their own task — a compromised agent can't impersonate another.

### Flow

1. **App generates token** at task assignment: `crypto.randomBytes(32).toString('hex')`
2. **Token stored** in `claude_sessions.callback_token` (unique index)
3. **Token delivered** to the agent:
   - **EC2**: written to SSM Parameter Store, read by bootstrap script
   - **Worker**: included in the `/api/worker/poll` response
4. **Agent includes token** as `Authorization: Bearer {token}` on all callbacks
5. **Route handler validates** token against DB and checks task ID matches

### Token delivery — EC2 (via SSM)

```typescript
// App writes token to SSM before launching the instance
await ssm.putParameter({
  Name: `/agent-army/tasks/${task.id}/callback-token`,
  Value: callbackToken,
  Type: 'SecureString',
  Overwrite: true,
});
```

```bash
# In startup.sh on the EC2 instance
CALLBACK_TOKEN=$(aws ssm get-parameter \
  --name "/agent-army/tasks/${TASK_ID}/callback-token" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text)

agent --task-id "$TASK_ID" --callback-token "$CALLBACK_TOKEN"
```

### Token delivery — worker (via poll response)

```json
// GET /api/worker/poll response includes the token
{
  "tasks": [{
    "id": 42,
    "title": "Fix login bug",
    "callbackToken": "a1b2c3d4...",
    // ... other task fields
  }]
}
```

### Token validation in route handler

```typescript
// app/api/agent/progress/route.ts
export async function POST(req: Request) {
  const token = req.headers.get('authorization')?.replace('Bearer ', '');

  const session = await db.claude_sessions.findByCallbackToken(token);
  if (!session) {
    return Response.json({ error: 'invalid token' }, { status: 401 });
  }

  // Verify taskId matches the session
  const body = await req.json();
  if (body.taskId !== session.task_id) {
    return Response.json({ error: 'task mismatch' }, { status: 403 });
  }

  // ... process progress update
}
```

## Tailscale ACLs

Network access is controlled by Tailscale ACL policy:

| From | To | Allowed |
|---|---|---|
| Members (you) | Agents | SSH + all ports |
| Agents | Internet | Yes (GitHub, npm, APIs) |
| Agent → Agent | Another agent | **Denied** |
| Internet → Agent | Any agent | **Denied** |

Agents are tagged `tag:agent` and isolated from each other. All inter-agent communication goes through the app's API.

See [tailscale.md](tailscale.md) for full ACL policy.

## Network Security

### EC2 agents

- **No public IPs** — instances are in a private subnet
- **NAT Gateway** for outbound only (GitHub, npm, APIs, Tailscale)
- **Security group**: no inbound rules (Tailscale handles connectivity)
- **All access via Tailscale** — encrypted WireGuard tunnel

### Personal devices

- **No inbound connections** from the worker daemon
- Worker only makes outbound HTTP requests to the app
- SSH access via Tailscale (same as EC2)

## IMDSv2 Enforcement

EC2 instances must use IMDSv2 (Instance Metadata Service v2), which requires a session token for metadata requests. This prevents SSRF attacks from reaching the metadata endpoint — an attacker would need to make two separate requests (PUT to get a token, then GET with the token), which standard SSRF payloads can't do.

All `RunInstances` calls include:

```typescript
await ec2.runInstances({
  // ... existing params ...
  MetadataOptions: {
    HttpTokens: 'required',        // IMDSv2 only (no IMDSv1 fallback)
    HttpPutResponseHopLimit: 1,    // Token can't traverse network hops
    HttpEndpoint: 'enabled',       // Metadata service is on
  },
});
```

`HttpPutResponseHopLimit: 1` ensures the token request can't be forwarded through a proxy or container — it must originate from the instance itself.

## 1Password SA Token via SSM

### Problem

EC2 user-data is readable by any process on the instance via the metadata endpoint (`http://169.254.169.254/latest/user-data`). Storing the 1Password service account token in user-data exposes it to any code running on the instance.

### Solution

Store the token in AWS Systems Manager Parameter Store as a `SecureString` (encrypted with KMS). The instance's IAM role grants read access.

**One-time setup:**

```bash
aws ssm put-parameter \
  --name "/agent-army/op-sa-token" \
  --value "ops_xxxxxxxx" \
  --type SecureString \
  --region us-west-1
```

**Updated bootstrap.sh:**

```bash
# Pull 1Password SA token from SSM (not user-data)
export OP_SERVICE_ACCOUNT_TOKEN=$(aws ssm get-parameter \
  --name "/agent-army/op-sa-token" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region us-west-1)
```

Only the agent instance role can read `/agent-army/*` parameters. See `iam/agent-instance-role-policy.json` for the `ReadSSMParams` statement.

## Budget Caps

Three levels of budget enforcement:

### Per-job budget

```typescript
// Set via @agent comment or /agent spawn --budget 10
const jobBudget = {
  scope: 'job',
  scope_id: job.id,
  max_amount: 10.00,  // $10 max for this job
  warn_threshold: 0.80,
};
```

### Per-day budget

```typescript
const dailyBudget = {
  scope: 'daily',
  max_amount: 50.00,  // $50/day across all agents
  warn_threshold: 0.80,
};
```

### Global budget

```typescript
const globalBudget = {
  scope: 'global',
  max_amount: 500.00, // $500 total monthly
  warn_threshold: 0.80,
};
```

### Enforcement logic

```typescript
async function checkBudget(jobId: number, additionalCost: number): Promise<BudgetCheck> {
  const jobSpent = await db.cost_events.sumByJob(jobId);
  const dailySpent = await db.cost_events.sumToday();
  const monthlySpent = await db.cost_events.sumThisMonth();

  const jobBudget = await db.budget_config.findByScope('job', jobId);
  const dailyBudget = await db.budget_config.findByScope('daily');
  const globalBudget = await db.budget_config.findByScope('global');

  // Check each level
  for (const [spent, budget, label] of [
    [jobSpent, jobBudget, 'job'],
    [dailySpent, dailyBudget, 'daily'],
    [monthlySpent, globalBudget, 'global'],
  ]) {
    if (!budget) continue;
    const projected = spent + additionalCost;
    const ratio = projected / budget.max_amount;

    if (ratio >= 1.0) {
      return { allowed: false, reason: `${label} budget exceeded ($${projected}/$${budget.max_amount})` };
    }
    if (ratio >= budget.warn_threshold) {
      await alertBudgetWarning(label, spent, budget.max_amount);
    }
  }

  return { allowed: true };
}
```

When budget is exceeded:
1. Agent is **paused** (not killed)
2. Slack alert: "Agent #7 paused — job budget exceeded ($10.24/$10.00)"
3. Linear comment: "Budget exceeded. Waiting for approval to continue."
4. Human can: increase budget, approve one-time override, or cancel

## Sub-Agent Depth Limits

Research and manage agents can spawn sub-agents. Depth is limited:

```typescript
const MAX_AGENT_DEPTH = 3;
// Level 0: root agent (e.g., research coordinator)
// Level 1: sub-agent (e.g., investigate module X)
// Level 2: sub-sub-agent (e.g., analyze specific file)
// Level 3: max — no further spawning

async function spawnSubAgent(parentTask: Task, subTaskDef: SubTaskDef) {
  const depth = await getAgentDepth(parentTask);
  if (depth >= MAX_AGENT_DEPTH) {
    throw new Error(`Max agent depth (${MAX_AGENT_DEPTH}) reached. Cannot spawn sub-agent.`);
  }
  // ... spawn sub-agent at depth + 1
}
```

## Human Checkpoints

Research agents pause for human review at configurable intervals:

```typescript
// After every N minutes of research, pause and ask for review
const RESEARCH_CHECKPOINT_INTERVAL = 30; // minutes

async function researchCheckpoint(agent: Agent) {
  await agent.pause();
  await postToSlack(agent.channelId,
    `:pause_button: Agent #${agent.id} checkpoint. Findings so far:\n${agent.currentFindings}\n\nReply "continue" to proceed or "stop" to terminate.`
  );
  await commentOnLinear(agent.jobId,
    `Research checkpoint. Review findings and reply to continue.`
  );
}
```

## Kill Switch

### Single agent

```bash
/agent stop 7          # graceful stop
/agent stop 7 --force  # immediate kill
```

### Kill tree (agent + all sub-agents)

```bash
/agent kill-tree 7
```

```typescript
async function killTree(rootTaskId: number) {
  const allTasks = await db.tasks.findTree(rootTaskId);

  for (const task of allTasks) {
    const session = await db.claude_sessions.findRunning(task.id);
    if (session) {
      await killSession(session);
    }
    if (task.resource?.type === 'ec2') {
      await ec2.terminateInstances({ InstanceIds: [task.resource.instance_id] });
    }
    await db.tasks.update(task.id, { status: 'cancelled' });
  }
}
```

### Emergency stop all

```bash
/agent stop all
```

Terminates all running agents, EC2 instances, and active sessions.

## Auto-Shutdown for Idle Instances

EC2 instances are terminated after a configurable idle period:

```typescript
const IDLE_TIMEOUT = 10 * 60 * 1000; // 10 minutes

async function checkIdleInstances() {
  const running = await db.resources.findByType('ec2', 'running');

  for (const resource of running) {
    const session = await db.claude_sessions.findRunning(resource.id);
    if (!session) {
      // No active session — instance is idle
      const idleTime = Date.now() - resource.updated_at.getTime();
      if (idleTime > IDLE_TIMEOUT) {
        await terminateResource(resource, 'idle timeout');
      }
    }
  }
}
```

## Audit Log

Every significant action is logged:

```sql
CREATE TABLE audit_log (
  id          SERIAL PRIMARY KEY,
  timestamp   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actor       TEXT NOT NULL,           -- 'app', 'user:jwu', 'agent:7'
  action      TEXT NOT NULL,           -- 'spawn', 'terminate', 'api_call', 'budget_warn', etc.
  target_type TEXT,                    -- 'job', 'task', 'resource', 'session'
  target_id   INTEGER,
  details     JSONB,
  cost        NUMERIC(10,4)            -- USD if applicable
);

CREATE INDEX idx_audit_timestamp ON audit_log(timestamp);
CREATE INDEX idx_audit_actor ON audit_log(actor);
CREATE INDEX idx_audit_action ON audit_log(action);
```

What gets logged:
- Every agent spawn and termination
- Every API call to external services
- Every cost event (compute and API)
- Budget warnings and enforcement actions
- Human commands (stop, restart, re-route)
- Device online/offline transitions
- Errors and failures

## Instance Type Constraints

The IAM policy (`iam/app-role-policy.json`) restricts which instance types the app can launch:

```json
{
  "Condition": {
    "StringEquals": {
      "ec2:InstanceType": [
        "t4g.medium",
        "t4g.large",
        "t4g.xlarge",
        "c7g.2xlarge",
        "mac2.metal",
        "mac2-m2pro.metal"
      ]
    }
  }
}
```

Even if the app code has a bug, AWS will deny launching unauthorized instance types.

## IAM Policy Hardening

Three additional IAM guardrails beyond instance type constraints:

### Fix PassRole wildcard

The `iam:PassRole` statement originally used a wildcard account ID (`::*:`). Fixed to use the actual account ID:

```json
// BEFORE (too broad)
"Resource": "arn:aws:iam::*:role/agent-instance-role"

// AFTER (scoped to our account)
"Resource": "arn:aws:iam::ACCOUNT_ID:role/agent-instance-role"
```

Replace `ACCOUNT_ID` with your actual AWS account ID (`aws sts get-caller-identity --query Account --output text`).

### Tag-based EC2 termination

`TerminateInstances` is split from the general EC2 lifecycle statement and requires the `project=agent-army` tag on the target instance:

```json
{
  "Sid": "EC2TerminateAgentsOnly",
  "Effect": "Allow",
  "Action": "ec2:TerminateInstances",
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "aws:RequestedRegion": "us-west-1",
      "ec2:ResourceTag/project": "agent-army"
    }
  }
}
```

This prevents the app from terminating instances it didn't create.

### Deny untagged launches

A `Deny` statement prevents launching instances without the `project=agent-army` tag:

```json
{
  "Sid": "DenyUntaggedLaunches",
  "Effect": "Deny",
  "Action": "ec2:RunInstances",
  "Resource": "arn:aws:ec2:us-west-1:*:instance/*",
  "Condition": {
    "StringNotEquals": {
      "aws:RequestTag/project": "agent-army"
    }
  }
}
```

This ensures every instance is tagged for cost tracking and lifecycle management.

See `iam/app-role-policy.json` for the full policy.

## Region Lock

All AWS operations are locked to `us-west-1` via IAM conditions:

```json
{
  "Condition": {
    "StringEquals": {
      "aws:RequestedRegion": "us-west-1"
    }
  }
}
```

This prevents accidental or malicious resource creation in other regions.
