# Linear Integration

> Linear is the source of truth for tasks. One label to activate, natural language comments for everything else.

## Single Label Activation

Only one label exists: **`agent`**.

- **Adding** the `agent` label to an issue → activates the system
- **Removing** the `agent` label → stops the agent and cancels the task

All configuration — skill selection, resource routing, model choice — happens through natural language comments. No label soup.

## Webhook Setup

Subscribe to these Linear webhook events:

```typescript
// Webhook URL: POST /api/webhooks/linear

// Events to subscribe:
// 1. Issue label changes (add/remove `agent` label)
// 2. Issue comments (commands, feedback)
```

### Webhook payload handling

```typescript
app.post('/api/webhooks/linear', async (req, reply) => {
  const { action, type, data } = req.body;

  if (type === 'Issue' && action === 'update') {
    // Check if `agent` label was added or removed
    const labelChange = detectLabelChange(data, 'agent');
    if (labelChange === 'added') {
      await handleAgentActivation(data);
    } else if (labelChange === 'removed') {
      await handleAgentDeactivation(data);
    }
  }

  if (type === 'Comment' && action === 'create') {
    // New comment on an issue — could be a command or feedback
    await handleComment(data);
  }

  reply.status(200).send({ ok: true });
});
```

## Comment-Based Commands

All commands are natural language. The app parses intent, not rigid syntax.

### Skill commands

| Comment | Effect |
|---|---|
| `@agent plan this` | Agent enriches the description with a plan, waits for approval |
| `@agent code this` | Agent starts coding immediately (this is the default) |
| `@agent review PR #42` | Agent reviews the specified PR |
| `@agent bench this` | Agent runs benchmarks |
| `@agent research this` | Agent starts deep research |
| `@agent explore the auth module` | Agent maps and documents the module |

### Routing commands

| Comment | Effect |
|---|---|
| `@agent code this on my laptop` | Routes to personal device |
| `@agent run on ec2` | Routes to EC2 |
| `@agent bench this on ec2` | Compute-optimized EC2 for benchmarks |
| `@agent run on ec2 instead` | Re-routes a queued task from device to EC2 |

### Configuration commands

| Comment | Effect |
|---|---|
| `@agent use opus` | Sets model to Opus |
| `@agent use sonnet` | Sets model to Sonnet |
| `@agent skills: plan, code, review` | Explicit skill assignment |

### Control commands

| Comment | Effect |
|---|---|
| `@agent stop` | Terminates the agent |
| `@agent restart` | Kills current session, starts fresh |
| `@agent approved, code it` | Resumes after plan approval |

### Feedback

Any comment while an agent is running that isn't a command is forwarded as feedback:

```
"use postgres not redis"
→ forwarded to agent as context, agent incorporates and continues

"the login page should have a dark mode toggle"
→ forwarded to agent, agent adjusts implementation

"looks good, but add tests for edge cases"
→ forwarded to agent, agent writes additional tests
```

### Intent parsing

```typescript
async function handleComment(data: LinearCommentData) {
  const { issueId, body, userId } = data;

  // Don't process our own comments (the app posts updates)
  if (userId === APP_LINEAR_USER_ID) return;

  const job = await db.jobs.findBy({ linear_issue_id: issueId });
  if (!job) return; // no active job for this issue

  const intent = parseIntent(body);

  switch (intent.type) {
    case 'skill':
      // "@agent plan this" → assign skills and start
      await assignSkillsAndStart(job, intent.skills, intent.routing);
      break;

    case 'config':
      // "@agent use opus" → update model
      await updateConfig(job, intent.config);
      break;

    case 'control':
      // "@agent stop" → terminate
      await handleControl(job, intent.action);
      break;

    case 'approval':
      // "@agent approved" → resume after plan
      await resumeAfterApproval(job);
      break;

    case 'feedback':
      // anything else → forward to running agent
      await forwardFeedback(job, body);
      break;
  }
}
```

## Custom Properties

Custom properties are metadata fields on Linear issues, managed by the app. They serve as a read-only status board for humans.

| Property | Type | Example Value |
|---|---|---|
| Agent ID | Number | `7` |
| Agent Status | Select | `provisioning` / `running` / `waiting` / `done` / `error` |
| Skills | Text | `plan, code, review` |
| Resource | Text | `agent-7 (EC2 t4g.xlarge)` or `jwu-macbook` |
| SSH | Text | `agent-7` or `jwu-macbook` |
| Model | Text | `opus` / `sonnet` |
| Branch | Text | `agent-7/fix-login-bug` |
| PR | URL | `https://github.com/org/repo/pull/42` |
| Compute Cost | Number | `1.24` |
| API Cost | Number | `3.50` |
| Total Cost | Number | `4.74` |
| Dashboard | URL | `https://dashboard.example.com/agents/7` |

### Updating custom properties

```typescript
import { LinearClient } from '@linear/sdk';

const linear = new LinearClient({ apiKey: process.env.LINEAR_API_KEY });

async function updateIssueProperties(issueId: string, agentState: AgentState) {
  await linear.issueUpdate(issueId, {
    // Custom properties are set via the customProperties field
    // The exact field names depend on your Linear workspace setup
  });

  // For custom properties, use the Linear API directly:
  await linear.createComment({
    issueId,
    body: formatStatusUpdate(agentState),
  });
}

function formatStatusUpdate(state: AgentState): string {
  return [
    `**Agent #${state.id}** — ${state.status}`,
    `Resource: ${state.resource}`,
    `Branch: \`${state.branch}\``,
    state.prUrl ? `PR: ${state.prUrl}` : null,
    `Cost: $${state.totalCost.toFixed(2)}`,
  ].filter(Boolean).join('\n');
}
```

## Task Sync

### Linear → App (inbound)

Linear is the source of truth for task descriptions:

```typescript
// When issue description is edited while agent is running:
async function handleIssueUpdate(data: LinearIssueData) {
  const job = await db.jobs.findBy({ linear_issue_id: data.id });
  if (!job) return;

  // Update job description
  await db.jobs.update(job.id, {
    title: data.title,
    description: data.description,
  });

  // If agent is running, forward the updated context
  const runningSession = await db.claude_sessions.findRunning(job.id);
  if (runningSession) {
    await forwardContextUpdate(runningSession, {
      title: data.title,
      description: data.description,
    });
  }
}
```

### App → Linear (outbound)

App writes status updates and custom properties:

```typescript
// On agent progress:
await linear.createComment({
  issueId: job.linear_issue_id,
  body: `Agent #${agentId}: ${progressSummary}`,
});

// On completion:
await linear.createComment({
  issueId: job.linear_issue_id,
  body: `Agent #${agentId} completed.\n\nPR: ${prUrl}\nBranch: \`${branch}\`\nCost: $${cost}`,
});

// On error:
await linear.createComment({
  issueId: job.linear_issue_id,
  body: `Agent #${agentId} failed: ${errorMessage}\n\nAttempt ${attempt}/${maxAttempts}`,
});
```

### Status mapping

| DB Status | Linear Workflow State |
|---|---|
| `pending` | Backlog |
| `queued` | Todo |
| `assigned` | Todo |
| `running` | In Progress |
| `completed` | Done |
| `failed` | Cancelled |
| `cancelled` | Cancelled |

## Workflow Examples

### Simple code task

```
1. You add `agent` label to LINEAR-123 "Fix login validation bug"
2. Webhook fires → app creates job + task (default skill: code)
3. App provisions EC2 (or dispatches to personal device)
4. Agent clones repo, reads issue, writes fix, runs tests
5. Agent creates branch `agent-7/fix-login-validation`
6. Agent opens PR, posts link to Linear
7. Agent calls /api/agent/complete
8. App updates Linear: status → Done, PR → link, costs
9. App posts to Slack: "Agent #7 completed LINEAR-123"
10. EC2 terminated (or device session cleaned up)
```

### Plan first, then code

```
1. You add `agent` label to LINEAR-456 "Redesign auth system"
2. You comment: "@agent plan this"
3. Agent explores codebase, produces detailed plan
4. Agent updates issue description with plan, comments "Plan ready for review"
5. You review the plan, make edits, comment: "@agent approved, code it"
6. Agent starts coding from the plan
7. ... (same completion flow as above)
```

### Feedback loop

```
1. Agent is running on LINEAR-789
2. You comment: "use postgres not redis for the session store"
3. Comment forwarded to agent as feedback
4. Agent adjusts implementation to use postgres
5. You comment: "looks good but add integration tests"
6. Agent writes integration tests
7. Agent completes, opens PR
```

### Routing to personal device

```
1. You add `agent` label to LINEAR-101
2. You comment: "@agent code this on my laptop"
3. App looks up resource "jwu-macbook" — status: online
4. Task queued → worker daemon picks it up on next poll
5. Worker starts Zellij session + Claude Code
6. App updates Linear: resource → "jwu-macbook"
7. ... (same completion flow)
```

### Offline device, then re-route

```
1. You comment: "@agent code this on my laptop"
2. App checks: jwu-macbook is offline
3. App queues task, comments: "Waiting for jwu-macbook to come online"
4. App posts to Slack: "Task queued for jwu-macbook — device offline"
5. Option A: laptop comes online → worker picks up task automatically
6. Option B: you comment "@agent run on ec2 instead" → task re-routed to EC2
```
