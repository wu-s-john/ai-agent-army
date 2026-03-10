# Data Model

> Entity graph and database schema for the AI Agent Army platform.

## Entity Relationship Diagram

```
                    ┌──────────┐
                    │  skills   │
                    └─────┬────┘
                          │ 1
                          │
                          │ *
                   ┌──────┴──────┐
                   │ agent_skills │
                   └──────┬──────┘
                          │ *
                          │
                          │ 1
┌──────┐    *   ┌─────────┴──────┐   *    ┌───────────┐
│ jobs │───────▶│     tasks      │◀───────│ resources │
└──────┘        └───┬─────────┬──┘        └─────┬─────┘
                    │ 1       │ 1               │ 1
                    │         │                 │
                    │ *       │ *               │ *
             ┌──────┴───┐  ┌─┴──────────┐  ┌──┴───────┐
             │task_agents│  │   claude_   │  │terminals │
             └───────────┘  │  sessions  │  └──┬───────┘
                            └──────┬─────┘     │ *
                                   │ 1         │
                                   │           │
                                   │ *         │ *
                            ┌──────┴───────────┴──┐
                            │   agent_terminals    │
                            └──────────────────────┘
```

**Key relationships:**
- A **job** has many **tasks** (a job can spawn sub-tasks)
- A **task** runs on one **resource** (EC2 instance or personal device)
- A **task** has many **claude_sessions** (retries, restarts)
- A **claude_session** has many **agent_terminals** (Zellij panes)
- A **resource** has many **terminals** (Zellij sessions on that machine)
- A **skill** is assigned to sessions via **agent_skills**
- **task_agents** tracks which sessions worked on which tasks (many-to-many)

## Tables

### jobs

Top-level work unit. One Linear issue = one job.

```sql
CREATE TABLE jobs (
  id              SERIAL PRIMARY KEY,
  linear_issue_id TEXT NOT NULL UNIQUE,
  linear_team_id  TEXT NOT NULL,
  title           TEXT NOT NULL,
  description     TEXT,
  status          TEXT NOT NULL DEFAULT 'pending',
  -- pending → active → completed / failed / cancelled
  priority        INTEGER DEFAULT 0,
  requested_by    TEXT,              -- Linear user who added the label
  model           TEXT DEFAULT 'sonnet', -- opus, sonnet, haiku
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at    TIMESTAMPTZ,
  metadata        JSONB DEFAULT '{}'
);

CREATE INDEX idx_jobs_status ON jobs(status);
CREATE INDEX idx_jobs_linear_issue ON jobs(linear_issue_id);
```

### tasks

A subtask within a job. Jobs can spawn sub-tasks for multi-step work.

```sql
CREATE TABLE tasks (
  id              SERIAL PRIMARY KEY,
  job_id          INTEGER NOT NULL REFERENCES jobs(id),
  parent_task_id  INTEGER REFERENCES tasks(id), -- for sub-tasks
  resource_id     INTEGER REFERENCES resources(id),
  title           TEXT NOT NULL,
  description     TEXT,
  status          TEXT NOT NULL DEFAULT 'queued',
  -- queued → assigned → running → completed / failed / cancelled
  routing         TEXT,              -- 'ec2', 'laptop', 'desktop', device name
  priority        INTEGER DEFAULT 0,
  attempt         INTEGER DEFAULT 1,
  max_attempts    INTEGER DEFAULT 3,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at      TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  result          JSONB,             -- completion data (pr_url, branch, summary)
  error           TEXT,
  metadata        JSONB DEFAULT '{}'
);

CREATE INDEX idx_tasks_job ON tasks(job_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_resource ON tasks(resource_id);
CREATE INDEX idx_tasks_queued ON tasks(status, resource_id) WHERE status = 'queued';
```

### resources

A compute target — either an EC2 instance or a personal device.

```sql
CREATE TABLE resources (
  id              SERIAL PRIMARY KEY,
  name            TEXT NOT NULL UNIQUE,   -- 'agent-7' or 'jwu-macbook'
  type            TEXT NOT NULL,          -- 'ec2' or 'device'
  status          TEXT NOT NULL DEFAULT 'pending',
  -- EC2:    pending → provisioning → running → terminated
  -- Device: offline → online → offline (cycles)

  -- EC2-specific
  instance_id     TEXT,                   -- AWS instance ID (i-xxx)
  instance_type   TEXT,                   -- t4g.xlarge, c7g.2xlarge, etc.
  ami_id          TEXT,
  spot            BOOLEAN DEFAULT false,

  -- Device-specific
  device_id       TEXT,                   -- unique device identifier
  owner           TEXT,                   -- who owns this device
  capabilities    JSONB,                  -- {maxSessions: 3, gpu: false, ...}

  -- Shared
  tailscale_ip    TEXT,
  tailscale_name  TEXT,                   -- MagicDNS hostname
  region          TEXT DEFAULT 'us-west-1',
  last_heartbeat  TIMESTAMPTZ,           -- for devices: online if < 2 min old
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  terminated_at   TIMESTAMPTZ,
  metadata        JSONB DEFAULT '{}'
);

CREATE INDEX idx_resources_type ON resources(type);
CREATE INDEX idx_resources_status ON resources(status);
CREATE INDEX idx_resources_instance ON resources(instance_id);
CREATE INDEX idx_resources_device ON resources(device_id);
```

### claude_sessions

A running Claude Code process. A task may have multiple sessions (retries).

```sql
CREATE TABLE claude_sessions (
  id              SERIAL PRIMARY KEY,
  task_id         INTEGER NOT NULL REFERENCES tasks(id),
  resource_id     INTEGER NOT NULL REFERENCES resources(id),
  status          TEXT NOT NULL DEFAULT 'starting',
  -- starting → running → completed / failed / killed
  model           TEXT NOT NULL DEFAULT 'sonnet',
  pid             INTEGER,               -- OS process ID
  zellij_session  TEXT,                  -- Zellij session name
  system_prompt   TEXT,                  -- compiled from skills
  branch          TEXT,                  -- git branch
  pr_url          TEXT,
  started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at        TIMESTAMPTZ,
  token_input     BIGINT DEFAULT 0,
  token_output    BIGINT DEFAULT 0,
  api_cost        NUMERIC(10,4) DEFAULT 0,
  metadata        JSONB DEFAULT '{}'
);

CREATE INDEX idx_sessions_task ON claude_sessions(task_id);
CREATE INDEX idx_sessions_resource ON claude_sessions(resource_id);
CREATE INDEX idx_sessions_status ON claude_sessions(status);
```

### agent_messages

Messages sent to a running agent (from Linear comments, Slack messages, PR reviews, dashboard).
The agent wrapper polls for unread messages and injects them into the Claude Code session.

```sql
CREATE TABLE agent_messages (
  id              SERIAL PRIMARY KEY,
  session_id      INTEGER NOT NULL REFERENCES claude_sessions(id),
  source          TEXT NOT NULL,          -- 'linear', 'slack', 'github', 'dashboard', 'system'
  sender          TEXT,                   -- username or system identifier
  body            TEXT NOT NULL,
  metadata        JSONB DEFAULT '{}',    -- source-specific data (PR path, line number, etc.)
  delivered       BOOLEAN DEFAULT false,  -- true once agent wrapper has polled it
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_agent_messages_session ON agent_messages(session_id);
CREATE INDEX idx_agent_messages_undelivered ON agent_messages(session_id, delivered) WHERE delivered = false;
```

### skills

Agent capabilities. Each skill injects a system prompt section.

```sql
CREATE TABLE skills (
  id              SERIAL PRIMARY KEY,
  name            TEXT NOT NULL UNIQUE,   -- 'plan', 'code', 'review', etc.
  description     TEXT,
  system_prompt   TEXT NOT NULL,          -- prompt injected when skill is active
  actions         TEXT[],                 -- allowed action categories
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### agent_skills

Join table: which skills are assigned to a session.

```sql
CREATE TABLE agent_skills (
  id              SERIAL PRIMARY KEY,
  session_id      INTEGER NOT NULL REFERENCES claude_sessions(id),
  skill_id        INTEGER NOT NULL REFERENCES skills(id),
  UNIQUE(session_id, skill_id)
);

CREATE INDEX idx_agent_skills_session ON agent_skills(session_id);
```

### task_agents

Join table: which sessions worked on which tasks. Enables history tracking when tasks are retried or handed off.

```sql
CREATE TABLE task_agents (
  id              SERIAL PRIMARY KEY,
  task_id         INTEGER NOT NULL REFERENCES tasks(id),
  session_id      INTEGER NOT NULL REFERENCES claude_sessions(id),
  role            TEXT DEFAULT 'primary', -- 'primary', 'reviewer', 'sub-agent'
  assigned_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(task_id, session_id)
);

CREATE INDEX idx_task_agents_task ON task_agents(task_id);
CREATE INDEX idx_task_agents_session ON task_agents(session_id);
```

### terminals

Zellij panes/tabs on a resource.

```sql
CREATE TABLE terminals (
  id              SERIAL PRIMARY KEY,
  resource_id     INTEGER NOT NULL REFERENCES resources(id),
  name            TEXT NOT NULL,          -- 'claude', 'shell', 'git'
  type            TEXT NOT NULL,          -- 'zellij_tab', 'zellij_pane'
  zellij_session  TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'active',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  closed_at       TIMESTAMPTZ
);

CREATE INDEX idx_terminals_resource ON terminals(resource_id);
```

### agent_terminals

Join table: which terminals belong to which claude session.

```sql
CREATE TABLE agent_terminals (
  id              SERIAL PRIMARY KEY,
  session_id      INTEGER NOT NULL REFERENCES claude_sessions(id),
  terminal_id     INTEGER NOT NULL REFERENCES terminals(id),
  purpose         TEXT,                  -- 'main', 'test-runner', 'watcher'
  UNIQUE(session_id, terminal_id)
);

CREATE INDEX idx_agent_terminals_session ON agent_terminals(session_id);
```

### cost_events

Granular cost tracking for billing and budget enforcement.

```sql
CREATE TABLE cost_events (
  id              SERIAL PRIMARY KEY,
  job_id          INTEGER REFERENCES jobs(id),
  task_id         INTEGER REFERENCES tasks(id),
  session_id      INTEGER REFERENCES claude_sessions(id),
  resource_id     INTEGER REFERENCES resources(id),
  type            TEXT NOT NULL,          -- 'compute', 'api', 'nat', 'storage'
  amount          NUMERIC(10,4) NOT NULL, -- USD
  description     TEXT,
  recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata        JSONB DEFAULT '{}'
);

CREATE INDEX idx_cost_events_job ON cost_events(job_id);
CREATE INDEX idx_cost_events_recorded ON cost_events(recorded_at);
```

### budget_config

Budget caps and thresholds.

```sql
CREATE TABLE budget_config (
  id              SERIAL PRIMARY KEY,
  scope           TEXT NOT NULL,          -- 'global', 'daily', 'job'
  scope_id        TEXT,                   -- job_id for per-job scope
  max_amount      NUMERIC(10,2) NOT NULL, -- USD
  warn_threshold  NUMERIC(3,2) DEFAULT 0.80, -- fraction (0.80 = 80%)
  active          BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

## Status State Machines

### Job Status

```
pending ──▶ active ──▶ completed
                  ├──▶ failed
                  └──▶ cancelled
```

- `pending`: created, no tasks started yet
- `active`: at least one task is running
- `completed`: all tasks completed successfully
- `failed`: a task failed and no retries remain
- `cancelled`: human cancelled (removed `agent` label or `@agent stop`)

### Task Status

```
queued ──▶ assigned ──▶ running ──▶ completed
                              ├──▶ failed ──▶ queued (retry)
                              └──▶ cancelled
```

- `queued`: waiting for a resource (device offline, or waiting for EC2)
- `assigned`: resource allocated, not yet started
- `running`: Claude Code is executing
- `completed`: finished successfully
- `failed`: agent reported error (may retry)
- `cancelled`: human cancelled

### Resource Status (EC2)

```
pending ──▶ provisioning ──▶ running ──▶ terminated
```

### Resource Status (Personal Device)

```
offline ◀──▶ online
```

Online = `last_heartbeat` < 2 minutes ago.

### Claude Session Status

```
starting ──▶ running ──▶ completed
                    ├──▶ failed
                    └──▶ killed
```

## Linear Sync

Linear is the **source of truth** for task descriptions and human-facing status. The app maintains bi-directional sync:

### App → Linear

When the app updates a task, it writes to Linear:
- **Custom properties**: agent ID, status, resource, SSH hostname, model, branch, PR URL, costs
- **Status**: maps DB status to Linear workflow state
- **Comments**: progress updates, error reports, completion summaries

### Linear → App

When a human edits the Linear issue, webhook pushes to app:
- **Comment added**: forwarded to running agent as feedback
- **Label removed**: triggers cancellation
- **Status changed**: reflected in DB (if human overrides)
- **Description edited**: forwarded to agent for context

### Status Mapping

| DB Status | Linear Status |
|---|---|
| `pending` | Backlog |
| `queued` | Todo |
| `assigned` | Todo |
| `running` | In Progress |
| `completed` | Done |
| `failed` | Cancelled (with error comment) |
| `cancelled` | Cancelled |
