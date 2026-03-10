# Architecture

> AI Agent Army — a platform to spawn AI coding agents on EC2 instances and personal devices, managed through Linear and Slack, connected via Tailscale.

## Overview

The system receives tasks from Linear (via labels and comments), provisions or dispatches to compute resources (EC2 instances or personal devices), runs Claude Code agents inside Zellij sessions, and reports progress back through Linear custom properties, Slack channels, and a web dashboard. Every agent is reachable over Tailscale for live SSH observation.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            YOU (operator)                              │
│   Linear · Slack · Dashboard · SSH (Tailscale) · Zed/VS Code Remote   │
└────┬──────────┬──────────┬──────────────────────────────────────┬──────┘
     │          │          │                                      │
     ▼          ▼          ▼                                      │
┌─────────────────────────────┐                                   │
│         APP (Fastify)       │                                   │
│  Vercel serverless / VPS    │                                   │
│                             │                                   │
│  ┌──────────┐ ┌──────────┐ │                                   │
│  │ Linear   │ │ Slack    │ │                                   │
│  │ webhooks │ │ commands │ │                                   │
│  └────┬─────┘ └────┬────┘ │                                   │
│       ▼             ▼      │                                   │
│  ┌─────────────────────┐   │      ┌──────────────────┐        │
│  │   Task Router       │   │      │    Postgres DB    │        │
│  │ (EC2 or personal?)  │───┼─────▶│ jobs, tasks,      │        │
│  └──┬──────────┬───────┘   │      │ sessions, etc.    │        │
│     │          │           │      └──────────────────┘        │
└─────┼──────────┼───────────┘                                   │
      │          │                                                │
      ▼          ▼                                                │
┌──────────┐  ┌────────────────────┐                             │
│  AWS EC2  │  │  Personal Devices  │                             │
│           │  │                    │                             │
│ agent-1   │  │ jwu-macbook        │◀────────────────────────────┘
│ agent-2   │  │ jwu-desktop        │         SSH via Tailscale
│ agent-3   │  │ build-server       │
│           │  │                    │
│ bootstrap │  │  worker daemon     │
│ → Claude  │  │  → Claude Code     │
│   Code    │  │                    │
└─────┬─────┘  └────────┬──────────┘
      │                  │
      ▼                  ▼
┌──────────────────────────────────────┐
│           Tailscale Network          │
│  agent-1.tailnet · jwu-macbook.tailnet │
│  MagicDNS · Tailscale SSH · ACLs    │
└──────────────────────────────────────┘
```

## Data Flow

```
1. Linear issue gets `agent` label (or @agent comment)
         │
         ▼
2. Linear webhook → App
         │
         ▼
3. App parses intent, creates job + task in Postgres
         │
         ▼
4. Router decides: EC2 or personal device?
        ╱ ╲
       ╱   ╲
      ▼     ▼
5a. EC2:              5b. Personal device:
    RunInstances →        Queue task in DB →
    bootstrap.sh →        Worker polls /api/worker/poll →
    Tailscale join →      Worker picks up task →
    Claude Code           Zellij + Claude Code
      │                     │
      ▼                     ▼
6. Agent callbacks: /api/agent/{ready,progress,complete,error}
         │
         ▼
7. App updates: Postgres → Linear properties → Slack channel
         │
         ▼
8. On completion: EC2 terminated / personal device session cleaned up
```

## Two Resource Types

| | EC2 (cloud) | Personal device |
|---|---|---|
| **Provisioning** | App creates/destroys via AWS SDK | Already running, user manages it |
| **Tailscale** | Installed in bootstrap.sh at boot | Installed once manually |
| **Task dispatch** | Bootstrap starts Claude Code with task context | Worker daemon polls for tasks |
| **Lifecycle** | Fully managed (create → terminate) | Device always-on, app manages sessions |
| **Cost** | EC2 + API costs tracked | API costs only |
| **Git auth** | GitHub token from Secrets Manager | GitHub token from local `.env` |

See [worker.md](worker.md) for personal device details, [infra.md](infra.md) for EC2 details.

## Workflows

### Single label activation

Add the `agent` label to any Linear issue → system activates. All configuration is via natural language comments:

```
@agent plan this                      → plan first, wait for approval
@agent code this                      → start coding (default)
@agent code this on my laptop         → route to personal device
@agent bench this on ec2              → compute-optimized EC2
@agent research this                  → long-running research agent
@agent review PR #42                  → review a pull request
@agent use opus                       → set model
@agent skills: plan, code, review     → custom skill set
@agent stop                           → terminate the agent
```

Any comment while an agent is running is forwarded as feedback. See [linear.md](linear.md) for full details.

## Tech Stack

| Component | Technology |
|---|---|
| App server | TypeScript / Fastify (Vercel serverless or VPS) |
| Database | Postgres (Vercel Postgres or RDS) |
| Compute (cloud) | AWS EC2 — Graviton ARM64 (t4g, c7g) + macOS (mac2) |
| Compute (personal) | Laptops, desktops, remote servers running worker daemon |
| Networking | Tailscale (WireGuard mesh, MagicDNS, Tailscale SSH) |
| AI | Claude Code (CLI) — Opus, Sonnet models |
| Task management | Linear (source of truth for tasks) |
| Communication | Slack (channels, threads, slash commands) |
| Source control | GitHub (HTTPS + token auth, gh CLI, webhooks) |
| Dashboard | Next.js on Vercel |
| Secrets | AWS Secrets Manager (EC2) / local `.env` (personal devices) |

## Entity Model

```
jobs ──────< tasks >────── resources
               │                │
               │                │
          task_agents      terminals
               │
               │
        claude_sessions ──< agent_terminals >── terminals
               │
          agent_skills
               │
             skills
```

- **Job**: a unit of work triggered from Linear (1 issue = 1 job)
- **Task**: a subtask within a job (jobs can spawn sub-tasks)
- **Resource**: a compute target — EC2 instance or personal device
- **Claude Session**: a running Claude Code process
- **Terminal**: a Zellij pane/tab
- **Skill**: a capability (plan, code, review, etc.)

See [data-model.md](data-model.md) for full schema.

## Agent Skills

Agents are configured with skills that determine their system prompt and allowed actions:

| Skill | Description |
|---|---|
| `plan` | Analyze requirements, break down work, produce implementation plan |
| `code` | Write code, run tests, create PRs |
| `review` | Review PRs, suggest improvements, check for issues |
| `bench` | Run benchmarks, analyze performance, compare results |
| `research` | Deep research across codebases/docs, produce reports |
| `manage` | Orchestrate sub-agents, coordinate multi-agent work |
| `deploy` | Run deployments, verify health, rollback if needed |
| `explore` | Explore unfamiliar codebases, map architecture, document findings |

See [agents.md](agents.md) for skill details, system prompts, and example configurations.

## Agent Lifecycle — EC2

```
1. TRIGGER     Linear webhook → app creates job + task
2. PROVISION   app calls ec2:RunInstances (spot or on-demand)
3. STARTUP     bootstrap.sh → install tools → join Tailscale → pull secrets
4. REGISTER    agent calls POST /api/agent/ready {instanceId, tailscaleIp}
5. EXECUTE     Claude Code runs with task context + skill-based system prompt
6. FEEDBACK    agent calls POST /api/agent/progress {status, summary}
7. COMPLETE    agent calls POST /api/agent/complete {result, pr_url, branch}
8. TEARDOWN    app terminates EC2 instance, Tailscale auto-removes ephemeral node
```

## Agent Lifecycle — Personal Device

```
1. TRIGGER     Linear webhook → app creates job + task, assigns to device
2. QUEUE       if device offline: task queued, Slack notified, Linear commented
3. DISPATCH    worker daemon polls GET /api/worker/poll → receives task
4. STARTUP     worker starts Zellij session + Claude Code
5. EXECUTE     Claude Code runs with task context + skill-based system prompt
6. FEEDBACK    worker calls POST /api/agent/progress (same endpoints as EC2)
7. COMPLETE    worker calls POST /api/agent/complete
8. CLEANUP     Zellij session cleaned up, worker ready for next task
```

## Resource Routing

When a task is triggered, the app decides where to run it:

| Signal | Routing |
|---|---|
| `on:laptop` / `on:desktop` / `on:server-name` | Specific personal device (queued if offline) |
| `on:ec2` or default | Spin up EC2 instance |
| `on:mac` | EC2 macOS dedicated host |
| No routing signal | App picks: prefer online personal devices, fall back to EC2 |
| Slack: `/agent spawn LINEAR-123 --on laptop` | Route via Slack command |

Offline handling: task queued → Slack notification → dispatched when device comes online → or re-routed via `@agent run on ec2 instead`.

## API Endpoints

### Webhook Receivers
| Method | Path | Source |
|---|---|---|
| POST | `/api/webhooks/linear` | Linear (label changes, comments) |
| POST | `/api/webhooks/github` | GitHub (PR reviews, comments, check status) |

### Agent Callbacks (used by both EC2 agents and worker daemon)
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/agent/ready` | Agent registered and ready |
| POST | `/api/agent/progress` | Status update during execution |
| POST | `/api/agent/complete` | Task completed successfully |
| POST | `/api/agent/error` | Task failed |

### Worker Daemon (personal devices)
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/worker/heartbeat` | Device heartbeat (every 30s) |
| GET | `/api/worker/poll` | Poll for queued tasks (every 5s) |

### Slack
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/slack/commands` | Slash command handler |
| POST | `/api/slack/events` | Event subscriptions |
| POST | `/api/slack/interactions` | Interactive message actions |

### Dashboard API
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/agents` | List all agents |
| GET | `/api/agents/:id` | Agent detail |
| GET | `/api/tasks` | List tasks |
| GET | `/api/resources` | List resources (EC2 + devices) |
| GET | `/api/resources/:id` | Resource detail |
| GET | `/api/costs` | Cost summary |
| POST | `/api/spawn` | Manual spawn from dashboard |

### GitHub Integration
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/webhooks/github` | PR reviews, comments, check statuses |

Agents interact with GitHub using a Personal Access Token (or GitHub App installation token) with `repo` scope. This single token covers all git and GitHub operations. See [github.md](github.md) for full GitHub API usage.

## Bootstrap & Instance Setup

### EC2 (bootstrap.sh)

The bootstrap script runs as user-data on EC2 launch. It installs:
- Build tools (git, curl, build-essential)
- Rust toolchain
- Node.js 22 + TypeScript
- Python 3
- Claude Code CLI
- Zed editor
- Zellij (terminal multiplexer)
- Modern CLI tools (ripgrep, fd, bat, fzf, eza, zoxide, dust)
- Starship prompt
- Zsh as default shell

After bootstrap, a startup script:
1. Pulls secrets from AWS Secrets Manager (Anthropic key, GitHub token)
2. Installs and joins Tailscale with ephemeral auth key
3. Clones the target repo using GitHub token (HTTPS)
4. Starts Zellij session
5. Launches Claude Code with task context
6. Calls POST `/api/agent/ready`

### Personal devices (worker daemon)

One-time setup:
1. Install worker: `npm install -g agent-worker`
2. Install Tailscale manually, join tailnet
3. Configure `.env` with app URL, device name, auth token, GitHub token, Anthropic key
4. Run: `agent-worker start`

See [worker.md](worker.md) for full details.

## Git & GitHub Integration

Agents use a GitHub token (PAT or GitHub App installation token) with `repo` scope for all git and GitHub operations:

- **Pushing code**: HTTPS + token (`https://x-access-token:${TOKEN}@github.com/org/repo.git`)
- **Creating PRs**: `gh pr create` (GitHub CLI, authenticated with same token)
- **Reading PR comments**: GitHub webhooks → app → forwarded to agent
- **Responding to reviews**: agent pushes fixes, comments via `gh` CLI

**Branch naming**: `agent-{id}/{issue-slug}` (e.g., `agent-7/fix-login-bug`)

See [github.md](github.md) for full GitHub API reference.

## Monitoring & Observability

| Method | What you see |
|---|---|
| **SSH via Tailscale** | `ssh agent-7` → live terminal, attach to Zellij session |
| **Zed/VS Code Remote** | Full IDE connected to agent via Tailscale |
| **Slack** | Real-time updates in agent channel/thread |
| **Linear** | Custom properties: status, resource, branch, PR, costs |
| **Dashboard** | Agent list, task detail, terminal output, cost tracking |
| **CloudWatch** | Instance metrics, application logs |

## Error Handling

| Scenario | Response |
|---|---|
| **Agent crash** | Process monitor detects exit, calls `/api/agent/error`, app updates Linear + Slack |
| **EC2 instance death** | Health check fails → app marks instance dead → Slack alert → option to retry |
| **Device offline mid-task** | Worker stops heartbeating → app marks task interrupted → Slack alert → task re-queued or re-routed |
| **Budget exceeded** | App pauses agent at budget cap → Slack alert → awaits human approval to continue |
| **Stuck agent** | No progress for configurable timeout → app sends warning → auto-terminates if no response |
| **Spot interruption** | 2-minute warning → agent commits WIP → app re-provisions on-demand |

## Cost Model

| Cost type | Applies to |
|---|---|
| EC2 compute | EC2 agents only |
| Claude API (tokens) | All agents (EC2 + personal devices) |
| macOS dedicated host | 24-hour minimum |
| NAT Gateway | EC2 agents |
| Tailscale | Free tier (up to 100 devices) |

Budget enforcement: warn at 80%, pause at 100%. Per-job, per-day, and global caps.

See [cost.md](cost.md) for pricing tables and enforcement logic.
