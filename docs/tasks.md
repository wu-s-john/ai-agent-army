# Tasks

> Implementation plan broken into milestones and tasks. Each milestone builds on the previous one.

## Milestone 0: Account Setup & Tokens

Goal: All accounts created, tokens generated, stored in 1Password, and infrastructure ready for Milestone 1.

### Task 0.1: 1Password vault setup

1. Create a shared vault called **"Agent Army"**
2. Install 1Password CLI: `brew install 1password-cli`
3. Verify: `op --version`

### Task 0.2: AWS account + IAM

1. Create AWS account (or use existing)
2. Create IAM roles using policies in `iam/`:
   - `app-role` — used by you locally and later by the Next.js app
     - Attach `iam/app-role-policy.json`
     - Trust policy: `iam/app-role-trust-policy.json`
   - `agent-instance-role` — attached to EC2 instances
     - Attach `iam/agent-instance-role-policy.json`
     - Trust policy: `iam/agent-instance-trust-policy.json`
   - Create instance profile for `agent-instance-role`
3. Create VPC in us-west-1:
   - VPC: `10.0.0.0/16`
   - Private subnet: `10.0.1.0/24` in `us-west-1a`
   - NAT Gateway (in a public subnet) for outbound internet
   - Internet Gateway
   - Route table: private subnet → NAT Gateway
4. Create security group `agent-sg`:
   - Inbound: none (Tailscale handles access)
   - Outbound: all traffic (0.0.0.0/0)
5. Configure AWS CLI locally: `aws configure` with app-role credentials, region `us-west-1`
6. Store AWS access key in 1Password vault (item: `aws-credentials`)

### Task 0.3: Tailscale setup

1. Create Tailscale account at [login.tailscale.com](https://login.tailscale.com)
2. Install Tailscale on your Mac: `brew install tailscale`
3. Join the tailnet: `tailscale up`
4. Generate an API key: Settings → Keys → Generate API Key
5. Store in 1Password vault (item: `tailscale-api-key`, field: `credential`)
6. Set up ACL policy (Settings → Access Controls):
   ```json
   {
     "acls": [
       {"action": "accept", "src": ["group:members"], "dst": ["tag:agent:*"]},
       {"action": "accept", "src": ["tag:agent"], "dst": ["autogroup:internet:*"]}
     ],
     "groups": {"group:members": ["dev@johnswu.net"]},
     "tagOwners": {"tag:agent": ["group:members"]},
     "ssh": [
       {"action": "accept", "src": ["group:members"], "dst": ["tag:agent"], "users": ["ubuntu", "root"]}
     ]
   }
   ```
7. (Optional) Rename tailnet: Settings → DNS → Rename

### Task 0.4: GitHub PAT

1. Go to GitHub → Settings → Developer Settings → Fine-grained personal access tokens
2. Create token with:
   - Repository access: all repos (or specific repos you want agents to work on)
   - Permissions: Contents (read/write), Pull Requests (read/write), Issues (read/write), Metadata (read)
3. Store in 1Password vault (item: `github-token`, field: `credential`)
4. Install GitHub CLI locally: `brew install gh`
5. Authenticate: `gh auth login`

### Task 0.5: Claude Code auth (Max plan)

For Milestones 1-2, agents use your Max subscription — no API key needed.

1. Verify Claude Code is installed locally: `claude --version`
2. Verify you're logged in: `claude` (should start without asking to log in)
3. **On EC2 (after Milestone 1)**: SSH into the instance and run `claude`
   - It will show a device code: "Visit https://claude.ai/device and enter code XXXX-XXXX"
   - Complete the OAuth flow in your browser
   - Claude Code on the instance now uses your Max plan
4. Note: this is a manual step per instance for now. API keys replace this at Milestone 3+.

### Task 0.6: 1Password service account

1. Go to 1password.com → Developer → Directory → Create a Service Account
2. Name: `agent-army-ec2`
3. Grant access to the **"Agent Army"** vault
4. Permissions: **Read Items**
5. **Save the token immediately** (shown only once)
6. Store the token in 1Password (in a separate admin vault or as a Secure Note)
7. Test it:
   ```bash
   export OP_SERVICE_ACCOUNT_TOKEN="ops_xxxxxxxx"
   op read "op://Agent Army/github-token/credential"
   # Should print your GitHub PAT
   ```

### Task 0.7: Verify everything

Run through this checklist:

```bash
# AWS
aws sts get-caller-identity                    # shows your account
aws ec2 describe-vpcs --region us-west-1       # shows your VPC

# Tailscale
tailscale status                               # shows your devices

# 1Password
op read "op://Agent Army/github-token/credential"      # prints token
op read "op://Agent Army/tailscale-api-key/credential"  # prints token

# GitHub
gh auth status                                 # shows logged in

# Claude Code
claude --version                               # shows version
```

---

## Milestone 1: Launch EC2 with coding environment

Goal: SSH into an EC2 instance from Zed with a fully set up coding environment.

### Task 1.1: EC2 launch script

Write a CLI script (`scripts/launch.ts`) that:
- Calls `ec2:RunInstances` (t4g.xlarge, Ubuntu ARM64 AMI, us-west-1, private subnet)
- Passes `bootstrap.sh` as user-data
- Tags the instance (`Name: agent-{id}`)
- Waits for instance to reach `running` state
- Outputs instance ID and private IP

**Depends on**: Task 0.2 (AWS IAM + VPC).

### Task 1.2: Tailscale integration in bootstrap

Extend `bootstrap.sh` to:
- Install Tailscale
- Join the tailnet with an ephemeral auth key (generated by launch script via Tailscale API)
- Set hostname to `agent-{id}`
- Enable Tailscale SSH

**Depends on**: Task 0.3 (Tailscale account + API key).

**Result**: `ssh agent-1` works from your Mac (Zed remote).

### Task 1.3: Secrets injection in bootstrap

Add a startup section to `bootstrap.sh` that:
- Uses 1Password CLI with the service account token to pull secrets
- Configures git HTTPS auth with the GitHub token (`op read`)
- Authenticates `gh` CLI

**Depends on**: Task 0.4 (GitHub PAT in 1Password), Task 0.6 (service account).

### Task 1.4: Claude Code login on EC2

After SSH-ing into the instance:
- Run `claude` to trigger the OAuth device code flow
- Complete login in your browser
- Claude Code now uses your Max plan on this instance

**Depends on**: Task 0.5 (Max plan active).

**Result**: Claude Code running on EC2, connected to your Max plan, with git/GitHub configured.

---

## Milestone 2: Agent wrapper

Goal: Run Claude Code programmatically on the EC2 instance, with a wrapper that can receive messages and report progress.

### Task 2.1: Scaffold agent-wrapper package

- Create `packages/agent-wrapper/`
- Set up TypeScript, tsconfig, build script
- Entry point: `src/index.ts`
- CLI: `agent-wrapper --task "description" --model sonnet`

### Task 2.2: Claude Code SDK integration

- Start a Claude Code session via the SDK
- Pass system prompt and task description
- Listen for events (tool use, output, completion, error)
- Log events to stdout for now

**Result**: run `agent-wrapper --task "review this PR"` on the EC2 instance, watch Claude Code work in the terminal.

### Task 2.3: Message injection

- Wrapper watches a local file (`./inbox/`) or accepts stdin for messages
- When a message appears, inject it into the Claude Code session as a user message
- Prefix with source: `[Human feedback]: ...`

**Result**: you can `echo "use postgres not redis" > inbox/001.txt` and the agent picks it up.

### Task 2.4: Graceful shutdown

- Handle SIGTERM: inject "commit WIP and push" message into Claude Code
- Wait up to 90s for git push
- Exit cleanly

---

## Milestone 3: Next.js app + API

Goal: Central app that manages state in Postgres and exposes API routes for the wrapper.

**New tokens needed**: Vercel account, Postgres database (Vercel Postgres or Neon).

### Task 3.1: Scaffold Next.js app

- Create `apps/web/` with `create-next-app` (App Router, TypeScript, Tailwind)
- Configure for Vercel deployment
- Set up project structure: `app/api/`, `lib/db/`, `lib/types/`

### Task 3.2: Database schema + migrations

- Set up Drizzle ORM (or Prisma) with Postgres
- Create migration files from the schema in `docs/data-model.md`
- Tables: jobs, tasks, resources, claude_sessions, agent_messages, skills, agent_skills, cost_events, budget_config, audit_log
- Seed skills table with the 8 skills from `docs/agents.md`

### Task 3.3: Agent callback API routes

Implement the agent → app endpoints:
- `POST /api/agent/ready` — register agent, update session status
- `POST /api/agent/progress` — update session status and summary
- `POST /api/agent/complete` — mark session complete, store result
- `POST /api/agent/error` — mark session failed, store error

### Task 3.4: Agent messaging API routes

Implement the app ↔ agent message endpoints:
- `POST /api/agent/:id/message` — write a message to `agent_messages` table
- `GET /api/agent/:id/messages` — return undelivered messages, mark as delivered
- `GET /api/agent/:id/status` — return current session status and context

### Task 3.5: Connect wrapper to app

Update agent-wrapper to:
- POST to `/api/agent/ready` on startup
- POST to `/api/agent/progress` on Claude Code events
- Poll `GET /api/agent/:id/messages` every 2s, inject into session
- POST to `/api/agent/complete` or `/api/agent/error` on exit

**Result**: end-to-end loop — you `curl POST /api/agent/:id/message` with feedback, agent receives it and responds.

### Task 3.6: Switch to API keys (optional)

When running multiple concurrent agents, switch from Max plan OAuth to API keys:
- Add `anthropic-key` to 1Password vault
- Update agent-wrapper to use `ANTHROPIC_API_KEY` env var
- Inject via `op run --env-file agent.env`

### Task 3.7: Integration tests

Vitest integration tests against a test Postgres:
- Agent lifecycle: ready → progress → complete
- Agent messaging: send message → poll → delivered
- Error handling: agent error → retry logic
- Budget enforcement: cost event → threshold → pause

---

## Milestone 4: One-click spawn

Goal: Single command spawns an EC2 instance, runs the agent, and reports back.

### Task 4.1: Spawn API route

- `POST /api/spawn` — accepts task description, model, instance type
- Creates job + task + resource in Postgres
- Generates Tailscale auth key via API
- Calls `ec2:RunInstances` with bootstrap + startup script
- Returns agent ID

### Task 4.2: Startup script (post-bootstrap)

A script that runs after `bootstrap.sh` finishes:
- Pulls task details from the app API
- Installs agent-wrapper from npm or repo
- Runs `agent-wrapper --task-id {id} --app-url {url}`
- Wrapper takes over from here

### Task 4.3: CLI spawn command

- `scripts/spawn.ts` — wraps the spawn API
- Usage: `npx spawn --task "Fix login bug in repo X" --model sonnet --instance t4g.xlarge`
- Outputs: agent ID, Tailscale hostname, dashboard URL

**Result**: one command → EC2 spins up → agent starts working → you SSH in from Zed to watch.

---

## Milestone 5: Linear + Slack integration

Goal: Trigger agents from Linear labels/comments, get updates in Slack.

**New tokens needed**: Linear API key, Slack bot app + token.

### Task 5.0: Linear + Slack account setup

1. **Linear**: Settings → API → Create Personal API Key → store in 1Password (`linear-api-key`)
2. **Linear**: Create `agent` label in your team
3. **Linear**: Set up custom properties (Agent ID, Status, Resource, SSH, Model, Branch, PR, Costs, Dashboard)
4. **Linear**: Create webhook (Settings → API → Webhooks) pointing to `/api/webhooks/linear`
5. **Slack**: Create app at [api.slack.com/apps](https://api.slack.com/apps)
6. **Slack**: Bot permissions: `channels:manage`, `chat:write`, `commands`, `users:read`
7. **Slack**: Create slash command `/agent`
8. **Slack**: Install to workspace, store bot token in 1Password (`slack-bot-token`)
9. **Slack**: Set event subscription URL to `/api/slack/events`

### Task 5.1: Linear webhook handler

- `POST /api/webhooks/linear`
- Detect `agent` label add/remove
- Parse comment intent (plan, code, review, etc.)
- Create job + task, trigger spawn

### Task 5.2: Linear property updates

- Update custom properties on agent progress (status, resource, branch, PR, costs)
- Post completion/error comments

### Task 5.3: Slack channel creation + updates

- Create channel per agent
- Post initial message with agent details
- Thread-based progress updates
- Completion message + channel archival

### Task 5.4: Slack slash commands

- `/agent spawn`, `/agent stop`, `/agent list`, `/agent status`
- Command parsing and handlers

### Task 5.5: Message forwarding (Linear + Slack → agent)

- Linear comment → `agent_messages` table → wrapper picks up
- Slack message in agent channel → `agent_messages` table → wrapper picks up

---

## Milestone 6: Worker daemon for personal devices

Goal: Run agents on your laptop/desktop, managed by the same app.

### Task 6.1: Worker daemon package

- Create `packages/worker/`
- Heartbeat loop (POST every 30s)
- Task polling loop (GET every 5s)
- CLI: `agent-worker start`, `agent-worker stop`, `agent-worker status`

### Task 6.2: Worker API routes

- `POST /api/worker/heartbeat` — update `last_heartbeat` in resources table
- `GET /api/worker/poll` — return queued tasks for this device

### Task 6.3: Task execution on personal device

- Worker receives task → starts Zellij session → runs agent-wrapper
- Same wrapper, same progress reporting, same message polling

### Task 6.4: Admission control

- Heartbeat includes live system stats (free memory, CPU load)
- App checks stats before assigning tasks
- Configurable max concurrent sessions per device

---

## Milestone 7: Dashboard

Goal: Web UI for monitoring agents, tasks, resources, and costs.

### Task 7.1: Agent list + detail pages

### Task 7.2: Task list page

### Task 7.3: Resource list + detail pages

### Task 7.4: Spawn form

### Task 7.5: Cost dashboard

---

## Milestone 8: GitHub integration

Goal: Agents create PRs, respond to reviews, react to CI failures.

**New tokens needed**: GitHub webhook setup.

### Task 8.0: GitHub webhook setup

1. In your GitHub repo(s): Settings → Webhooks → Add webhook
2. Payload URL: `/api/webhooks/github`
3. Events: Pull request reviews, Pull request review comments, Issue comments, Check suites

### Task 8.1: GitHub webhook handler

- `POST /api/webhooks/github`
- PR review comments → agent_messages
- CI failures → agent_messages

### Task 8.2: PR workflow in agent wrapper

- Agent creates branch, pushes, opens PR via `gh`
- Wrapper reports PR URL to app
- App updates Linear properties

---

## Priority

**Start here**: Milestone 0 (setup), then Milestones 1-3 are the foundation.

Milestone 4 (one-click spawn) is the first "it works end-to-end" moment.

Milestone 5 (Linear + Slack) is where it becomes actually useful day-to-day.
