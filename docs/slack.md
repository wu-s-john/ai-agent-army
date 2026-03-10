# Slack Integration

> Real-time agent updates, slash commands, and message forwarding via Slack.

## Slash Commands

All commands use the `/agent` prefix:

| Command | Description |
|---|---|
| `/agent spawn LINEAR-123` | Spawn an agent for a Linear issue |
| `/agent spawn LINEAR-123 --on laptop` | Spawn on a specific device |
| `/agent spawn LINEAR-123 --skills plan,code` | Spawn with specific skills |
| `/agent spawn LINEAR-123 --model opus` | Spawn with a specific model |
| `/agent stop 7` | Stop agent #7 |
| `/agent stop all` | Stop all running agents |
| `/agent list` | List all active agents |
| `/agent status 7` | Detailed status of agent #7 |
| `/agent terminal 7` | Show terminal output for agent #7 |
| `/agent bench LINEAR-456 --on ec2` | Start a benchmark agent on EC2 |
| `/agent report` | Daily cost and activity summary |
| `/agent report weekly` | Weekly summary |

### Command handler

```typescript
app.post('/api/slack/commands', async (req, reply) => {
  const { command, text, user_id, channel_id } = req.body;

  if (command !== '/agent') {
    return reply.status(200).send({ text: 'Unknown command' });
  }

  const args = parseSlackCommand(text);

  switch (args.action) {
    case 'spawn':
      await handleSpawn(args, user_id, channel_id);
      break;
    case 'stop':
      await handleStop(args, user_id);
      break;
    case 'list':
      await handleList(channel_id);
      break;
    case 'status':
      await handleStatus(args.agentId, channel_id);
      break;
    case 'terminal':
      await handleTerminal(args.agentId, channel_id);
      break;
    case 'report':
      await handleReport(args.period, channel_id);
      break;
    default:
      return reply.status(200).send({ text: `Unknown action: ${args.action}` });
  }

  // Acknowledge immediately (Slack requires response within 3s)
  reply.status(200).send();
});
```

## Channel Creation

Each agent gets a Slack channel for updates.

### Naming convention

```
#agent-7-fix-login-bug      (coder)
#agent-12-perf-benchmarks   (bencher)
#research-auth-redesign      (researcher — different prefix)
```

### Channel setup

```typescript
import { WebClient } from '@slack/web-api';

const slack = new WebClient(process.env.SLACK_BOT_TOKEN);

async function createAgentChannel(agent: Agent, task: Task): Promise<string> {
  const slug = slugify(task.title, 30); // max 30 chars for readability
  const name = agent.skills.includes('research')
    ? `research-${slug}`
    : `agent-${agent.id}-${slug}`;

  // Create channel
  const { channel } = await slack.conversations.create({
    name,
    is_private: false,
  });

  // Set topic
  await slack.conversations.setTopic({
    channel: channel.id,
    topic: `Agent #${agent.id} | ${task.title} | LINEAR-${task.linearId}`,
  });

  // Post initial message
  await slack.chat.postMessage({
    channel: channel.id,
    blocks: [
      {
        type: 'header',
        text: { type: 'plain_text', text: `Agent #${agent.id} Started` },
      },
      {
        type: 'section',
        fields: [
          { type: 'mrkdwn', text: `*Task:* ${task.title}` },
          { type: 'mrkdwn', text: `*Linear:* <${task.linearUrl}|${task.linearId}>` },
          { type: 'mrkdwn', text: `*Resource:* ${agent.resource}` },
          { type: 'mrkdwn', text: `*Skills:* ${agent.skills.join(', ')}` },
          { type: 'mrkdwn', text: `*Model:* ${agent.model}` },
          { type: 'mrkdwn', text: `*SSH:* \`ssh ${agent.tailscaleName}\`` },
        ],
      },
    ],
  });

  return channel.id;
}
```

## Update Patterns

### Coders and benchers: thread-based

For code and bench agents, updates go in a thread under the initial message. This keeps the channel clean — one top-level message, progress in the thread.

```typescript
async function postProgress(channelId: string, threadTs: string, message: string) {
  await slack.chat.postMessage({
    channel: channelId,
    thread_ts: threadTs,
    text: message,
  });
}

// Example progress updates:
// "Exploring codebase... found 3 relevant files"
// "Writing implementation in src/auth/validate.ts"
// "Tests passing (12/12)"
// "Created branch: agent-7/fix-login-bug"
// "PR opened: https://github.com/org/repo/pull/42"
```

### Researchers: channel as command center

Research agents use the channel itself (not threads) because they:
- Run for longer periods
- Spawn sub-agents
- Produce structured results

```typescript
// Sub-agent spawn notification
await slack.chat.postMessage({
  channel: channelId,
  blocks: [
    {
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: ':mag: *Sub-agent spawned:* Investigating authentication patterns in `src/auth/`',
      },
    },
  ],
});

// Periodic progress
await slack.chat.postMessage({
  channel: channelId,
  text: ':clock3: *Progress (15m):* Analyzed 3/7 modules. Key finding: auth middleware is duplicated across 4 routes.',
});

// Results table
await slack.chat.postMessage({
  channel: channelId,
  blocks: [
    {
      type: 'header',
      text: { type: 'plain_text', text: 'Research Results' },
    },
    {
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: [
          '| Module | Status | Notes |',
          '|---|---|---|',
          '| auth | :white_check_mark: | Well-structured, needs tests |',
          '| api | :warning: | Missing validation on 3 endpoints |',
          '| db | :white_check_mark: | Clean, good migration pattern |',
        ].join('\n'),
      },
    },
  ],
});
```

## Message Forwarding

### Slack → Agent

Messages posted in an agent's channel are written to the `agent_messages` table. The agent wrapper polls for new messages and injects them into the Claude Code session.

```typescript
// Subscribe to message events in agent channels
app.post('/api/slack/events', async (req, reply) => {
  const { event } = req.body;

  // Verify it's a message in an agent channel
  if (event.type === 'message' && !event.bot_id) {
    const agent = await findAgentByChannel(event.channel);
    if (agent && agent.status === 'running') {
      // Look up Slack username
      const userInfo = await slack.users.info({ user: event.user });

      // Write to agent_messages table
      // Agent wrapper polls GET /api/agent/:id/messages every 2s
      await db.agent_messages.create({
        session_id: agent.sessionId,
        source: 'slack',
        sender: userInfo.user.real_name,
        body: event.text,
      });
    }
  }

  reply.status(200).send({ challenge: req.body.challenge });
});
```

### Agent → Slack

Agents post responses back to their channel:

```typescript
// Agent calls POST /api/agent/progress with a message for Slack
app.post('/api/agent/progress', async (req, reply) => {
  const { agentId, status, summary, slackMessage } = req.body;

  // Update DB
  await updateAgentProgress(agentId, status, summary);

  // Post to Slack if agent included a message
  if (slackMessage) {
    const agent = await db.agents.find(agentId);
    await slack.chat.postMessage({
      channel: agent.slackChannelId,
      thread_ts: agent.slackThreadTs,
      text: slackMessage,
    });
  }

  reply.status(200).send({ ok: true });
});
```

## Completion & Archival

### Completion message

```typescript
async function postCompletion(agent: Agent, result: TaskResult) {
  await slack.chat.postMessage({
    channel: agent.slackChannelId,
    blocks: [
      {
        type: 'header',
        text: { type: 'plain_text', text: `Agent #${agent.id} Completed` },
      },
      {
        type: 'section',
        fields: [
          { type: 'mrkdwn', text: `*Result:* ${result.summary}` },
          { type: 'mrkdwn', text: `*PR:* <${result.prUrl}|View PR>` },
          { type: 'mrkdwn', text: `*Branch:* \`${result.branch}\`` },
          { type: 'mrkdwn', text: `*Duration:* ${result.duration}` },
          { type: 'mrkdwn', text: `*Cost:* $${result.totalCost.toFixed(2)}` },
        ],
      },
    ],
  });
}
```

### Channel archival

After completion, channels are archived to keep the workspace clean:

```typescript
async function archiveAgentChannel(agent: Agent) {
  // Wait a bit so humans can see the completion message
  // (this runs as a delayed job, not a setTimeout)

  await slack.conversations.archive({
    channel: agent.slackChannelId,
  });
}
```

Archived channels are searchable and can be unarchived if needed.

## Alerts

### Budget alerts

```typescript
await slack.chat.postMessage({
  channel: ALERTS_CHANNEL,
  text: `:warning: Agent #${agentId} reached 80% of budget ($${spent}/$${budget}). Will pause at 100%.`,
});
```

### Error alerts

```typescript
await slack.chat.postMessage({
  channel: ALERTS_CHANNEL,
  text: `:x: Agent #${agentId} failed: ${error}\nTask: ${task.title}\nResource: ${resource.name}`,
});
```

### Device offline alerts

```typescript
await slack.chat.postMessage({
  channel: ALERTS_CHANNEL,
  text: `:warning: Task queued for ${device.name} — device is offline. Re-route with \`/agent spawn ${taskId} --on ec2\``,
});
```
