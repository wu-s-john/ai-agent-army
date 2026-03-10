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
