# Worker Daemon

> A lightweight TypeScript process that runs on personal devices (laptops, desktops, remote servers) to receive and execute agent tasks.

## Overview

The worker daemon bridges personal devices into the agent platform. It's fully HTTP-based — no WebSockets, no extra services. Compatible with Vercel serverless.

```
┌──────────────────────────────┐          ┌──────────────────┐
│       Personal Device         │          │   App (Vercel)    │
│                               │          │                   │
│  ┌─────────────────────────┐ │  HTTP    │  ┌─────────────┐ │
│  │    Worker Daemon         │◀┼─────────┼─▶│  Serverless  │ │
│  │                          │ │          │  │  Functions   │ │
│  │  heartbeat (POST 30s)   │ │          │  └──────┬──────┘ │
│  │  poll tasks (GET 5s)    │ │          │         │        │
│  │  report progress (POST) │ │          │  ┌──────┴──────┐ │
│  │                          │ │          │  │  Postgres    │ │
│  │  ┌──────────────────┐   │ │          │  └─────────────┘ │
│  │  │ Zellij + Claude  │   │ │          └──────────────────┘
│  │  │ Code sessions    │   │ │
│  │  └──────────────────┘   │ │
│  └─────────────────────────┘ │
└──────────────────────────────┘
```

## Installation

### From npm (recommended)

```bash
npm install -g @agent-army/worker
```

### From repo

```bash
git clone https://github.com/org/agent-army.git
cd agent-army/packages/worker
npm install && npm run build
npm link
```

## Configuration

Create `.env` in the worker directory (or export environment variables):

```bash
# Required
AGENT_WORKER_APP_URL=https://your-app.vercel.app  # App base URL
AGENT_WORKER_DEVICE_NAME=jwu-macbook               # Unique device name
AGENT_WORKER_AUTH_TOKEN=wkr_xxxxxxxxxxxx            # Auth token from app

# Git / AI (used by Claude Code sessions)
GITHUB_TOKEN=ghp_xxxxxxxxxxxx                       # GitHub PAT (repo scope)
ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxx               # Claude API key

# Optional
AGENT_WORKER_POLL_INTERVAL=5000                     # Task poll interval (ms, default: 5000)
AGENT_WORKER_HEARTBEAT_INTERVAL=30000               # Heartbeat interval (ms, default: 30000)
AGENT_WORKER_MAX_SESSIONS=3                         # Max concurrent sessions (default: 3)
AGENT_WORKER_WORK_DIR=~/agent-work                  # Working directory for repos
```

## HTTP Protocol

The worker communicates with the app using simple HTTP requests. No WebSockets, no long-polling, no SSE. Fully stateless on the server side.

### Heartbeat

POST `/api/worker/heartbeat` every 30 seconds.

```typescript
// Worker sends:
POST /api/worker/heartbeat
Authorization: Bearer wkr_xxxxxxxxxxxx
Content-Type: application/json

{
  "deviceId": "jwu-macbook",
  "status": "idle",                    // idle | busy | full
  "activeSessions": 1,
  "maxSessions": 3,
  "capabilities": {
    "os": "darwin",
    "arch": "arm64",
    "totalMemoryMB": 32768,
    "gpu": true
  },
  "system": {                          // live stats for admission control
    "memoryFreeMB": 12800,
    "cpuLoadAvg": 2.1,
    "diskFreeGB": 45
  }
}

// App responds:
200 OK
{ "ok": true }
```

The app updates `last_heartbeat` and `capabilities` in the `resources` table. A device is considered **online** if its last heartbeat is < 2 minutes old.

### Admission control

The app checks live system stats before assigning tasks:

```typescript
async function canAcceptTask(device: Resource): boolean {
  const activeSessions = await db.claude_sessions.countActive(device.id);

  // Hard limit from config
  if (activeSessions >= device.capabilities.maxSessions) return false;

  // Memory check: each Claude Code session uses ~2-4 GB
  const memPerSession = 3 * 1024; // 3 GB in MB
  const freeMemory = device.capabilities.system?.memoryFreeMB ?? 0;
  if (freeMemory < memPerSession) return false;

  return true;
}
```

### Task polling

GET `/api/worker/poll` every 5 seconds.

```typescript
// Worker sends:
GET /api/worker/poll?deviceId=jwu-macbook
Authorization: Bearer wkr_xxxxxxxxxxxx

// App responds (no tasks):
200 OK
{ "tasks": [] }

// App responds (task available):
200 OK
{
  "tasks": [
    {
      "id": 42,
      "jobId": 7,
      "title": "Fix login validation bug",
      "description": "The login form accepts empty passwords...",
      "repo": "https://github.com/org/repo",
      "branch": "main",
      "skills": ["code"],
      "model": "sonnet",
      "systemPrompt": "You are Agent #7...",
      "callbackUrl": "https://your-app.vercel.app/api/agent"
    }
  ]
}
```

When the worker picks up a task, the app marks it as `assigned` so it won't be returned to other polls.

### Progress reporting

Same endpoints as EC2 agents:

```typescript
// Ready
POST /api/agent/ready
{ "taskId": 42, "resourceName": "jwu-macbook", "tailscaleIp": "100.x.y.z" }

// Progress
POST /api/agent/progress
{ "taskId": 42, "status": "running", "summary": "Writing implementation..." }

// Complete
POST /api/agent/complete
{ "taskId": 42, "result": { "prUrl": "...", "branch": "...", "summary": "..." } }

// Error
POST /api/agent/error
{ "taskId": 42, "error": "Tests failed after 3 attempts" }
```

## Online/Offline Detection

The app determines device availability by checking `last_heartbeat`:

```typescript
function isDeviceOnline(resource: Resource): boolean {
  if (resource.type !== 'device') return false;
  if (!resource.last_heartbeat) return false;
  const age = Date.now() - resource.last_heartbeat.getTime();
  return age < 2 * 60 * 1000; // 2 minutes
}
```

When a device goes offline (heartbeat stops):
1. App marks device as `offline` after 2 minutes
2. Running tasks on that device are marked `interrupted`
3. Slack alert posted
4. Tasks can be re-routed to EC2

When a device comes back online (heartbeat resumes):
1. App marks device as `online`
2. Worker polls for queued tasks
3. Queued tasks for this device are dispatched automatically

## Task Execution

When the worker receives a task from polling, it starts the **agent wrapper** — a thin TypeScript process that manages Claude Code via the SDK and handles all communication with the app.

```typescript
async function executeTask(task: WorkerTask) {
  const workDir = path.join(WORK_DIR, `task-${task.id}`);

  // 1. Clone or update repo
  await cloneRepo(task.repo, task.branch, workDir);

  // 2. Configure git
  await configureGit(workDir, task);

  // 3. Start Zellij session
  const sessionName = `agent-${task.jobId}-task-${task.id}`;
  await startZellijSession(sessionName, workDir);

  // 4. Start agent wrapper (runs Claude Code via SDK)
  const wrapper = new Agent({
    taskId: task.id,
    sessionId: task.sessionId,
    appUrl: APP_URL,
    authToken: AUTH_TOKEN,
    model: task.model,
    systemPrompt: task.systemPrompt,
    workDir,
    zellijSession: sessionName,
  });

  // 5. Wrapper handles everything:
  //    - Starts Claude Code session via SDK
  //    - Reports ready to app
  //    - Polls for messages (feedback, commands) every 2s
  //    - Injects messages into Claude Code session
  //    - Reports progress on tool use events
  //    - Reports completion/error on exit
  //    - Handles SIGTERM for graceful shutdown
  await wrapper.run();
}
```

### Agent wrapper internals

```typescript
class Agent {
  private session: ClaudeCodeSession;
  private messagePoller: NodeJS.Timeout;

  async run() {
    // Start Claude Code via SDK
    this.session = await ClaudeCode.startSession({
      model: this.config.model,
      systemPrompt: this.config.systemPrompt,
      workDir: this.config.workDir,
    });

    // Report ready
    await this.post('/api/agent/ready', {
      taskId: this.config.taskId,
      resourceName: DEVICE_NAME,
    });

    // Poll for inbound messages (Linear comments, Slack, PR reviews)
    this.messagePoller = setInterval(() => this.pollMessages(), 2000);

    // Listen for Claude Code events
    this.session.on('toolUse', (event) => {
      this.post('/api/agent/progress', {
        taskId: this.config.taskId,
        status: 'running',
        summary: `${event.tool}: ${event.description}`,
      });
    });

    // Handle graceful shutdown (spot interruption, stop command)
    process.on('SIGTERM', () => this.handleShutdown());

    // Wait for completion
    const result = await this.session.waitForCompletion();

    clearInterval(this.messagePoller);
    await this.post('/api/agent/complete', {
      taskId: this.config.taskId,
      result,
    });
  }

  private async pollMessages() {
    const { messages } = await this.get(
      `/api/agent/${this.config.sessionId}/messages`
    );

    for (const msg of messages) {
      // Inject into Claude Code session as user message
      const prefix = msg.source === 'github'
        ? `[PR review from ${msg.sender}]`
        : `[${msg.source} from ${msg.sender}]`;

      await this.session.sendMessage(`${prefix}: ${msg.body}`);
    }
  }

  private async handleShutdown() {
    await this.session.sendMessage(
      'URGENT: This session is being terminated. ' +
      'Commit all work-in-progress NOW and push. ' +
      'Run: git add -A && git commit -m "WIP: session terminated" && git push'
    );
    // Wait up to 90s for push
    await this.session.waitForCompletion({ timeout: 90_000 });
    process.exit(0);
  }
}
```

### Git configuration

```typescript
async function configureGit(workDir: string, task: WorkerTask) {
  // HTTPS auth via GitHub token
  await exec(`git config url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"`, { cwd: workDir });

  // GitHub CLI auth
  await exec(`echo "${GITHUB_TOKEN}" | gh auth login --with-token`);

  // Create agent branch
  const branch = `agent-${task.jobId}/${slugify(task.title)}`;
  await exec(`git checkout -b ${branch}`, { cwd: workDir });
}
```

## Session Management

### Start a session

```typescript
async function startZellijSession(name: string, workDir: string) {
  // Create session with layout
  await exec(`zellij --session ${name} --new-session-with-layout ${LAYOUT_PATH}`, {
    cwd: workDir,
    detached: true,
  });
}
```

### Zellij layout

Same as EC2 agents:

```kdl
// agent-layout.kdl
layout {
  tab name="claude" {
    pane command="claude" {
      // Claude Code runs here
    }
  }
  tab name="shell" {
    pane
  }
  tab name="git" {
    pane command="git" {
      args "log" "--oneline" "-20"
    }
  }
}
```

### Stop a session

```typescript
async function stopSession(name: string) {
  await exec(`zellij kill-session ${name}`);
}
```

### Restart a session

```typescript
async function restartSession(name: string, task: WorkerTask) {
  await stopSession(name);
  await startZellijSession(name, task.workDir);
  await launchClaudeCode(name, task);
}
```

## Multiple Concurrent Sessions

The worker can run multiple agents on the same device:

```typescript
class WorkerDaemon {
  private sessions: Map<number, AgentSession> = new Map();
  private maxSessions: number;

  async pollForTasks() {
    if (this.sessions.size >= this.maxSessions) {
      // Report status as 'full' in heartbeat
      return;
    }

    const { tasks } = await this.poll();
    for (const task of tasks) {
      if (this.sessions.size < this.maxSessions) {
        const session = await this.executeTask(task);
        this.sessions.set(task.id, session);
      }
    }
  }

  getStatus(): 'idle' | 'busy' | 'full' {
    if (this.sessions.size === 0) return 'idle';
    if (this.sessions.size >= this.maxSessions) return 'full';
    return 'busy';
  }
}
```

The `maxSessions` is configurable (default: 3). The heartbeat reports current status so the app knows not to assign more tasks than the device can handle.

## Queued Tasks

When a device is offline, tasks wait in the DB:

```
Task status: queued
Task resource_id: (jwu-macbook's resource ID)
```

When the worker comes online and polls:
1. App returns all queued tasks for this device
2. Worker picks them up in priority order
3. Tasks transition: `queued` → `assigned` → `running`

### Re-routing

Tasks can be re-routed while queued:

```
@agent run on ec2 instead
```

App cancels the device assignment and spawns an EC2 instance instead.

## Security

- **Auth token**: every HTTP request includes `Authorization: Bearer wkr_xxx`
- **Token generation**: tokens are created in the app dashboard, scoped to a specific device
- **Secrets**: stored locally in `.env` — not pulled from AWS Secrets Manager
- **No inbound connections**: worker only makes outbound HTTP requests
- **Callback tokens**: agent callback endpoints (`/api/agent/*`) use per-session tokens. See [security.md](security.md#per-session-callback-tokens).
- **Tailscale**: device is on the tailnet for SSH access, but the worker itself doesn't use Tailscale for communication

## CLI Commands

```bash
# Start the worker daemon
agent-worker start

# Start in foreground (for debugging)
agent-worker start --foreground

# Check status
agent-worker status
# Output:
# Worker: running (PID 12345)
# Device: jwu-macbook
# Status: busy (2/3 sessions)
# Sessions:
#   task-42: running (12m) — Fix login validation
#   task-43: running (3m)  — Add dark mode toggle

# Stop the worker (gracefully finishes running sessions)
agent-worker stop

# Stop immediately (kills sessions)
agent-worker stop --force

# View logs
agent-worker logs
agent-worker logs --follow
```

### Process management

The worker runs as a background process (or systemd service on Linux):

```bash
# macOS: launchd plist (created by `agent-worker install`)
~/Library/LaunchAgents/com.agent-army.worker.plist

# Linux: systemd service
~/.config/systemd/user/agent-worker.service
```

### Auto-start on login

```bash
# Install as login service (macOS launchd or Linux systemd)
agent-worker install

# Remove login service
agent-worker uninstall
```
