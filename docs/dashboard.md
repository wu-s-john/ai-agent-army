# Web Dashboard

> Next.js on Vercel, fully serverless. No WebSockets — polling-based real-time updates.

## Tech Stack

| Component | Choice |
|---|---|
| Framework | Next.js (App Router) |
| Hosting | Vercel (serverless) |
| Data fetching | SWR (stale-while-revalidate) |
| Styling | Tailwind CSS |
| UI components | Radix UI primitives |

No WebSockets — the dashboard polls the API for updates. SWR handles caching, deduplication, and background refresh.

## Pages

### `/` — Home

Overview dashboard with key metrics:

- Active agents count
- Queued tasks count
- Online personal devices
- Today's spend vs budget
- Recent activity feed (last 10 events)

Refresh: every 30s.

### `/agents` — Agent List

| Column | Example |
|---|---|
| ID | #7 |
| Status | Running / Completed / Error |
| Task | Fix login validation bug |
| Resource | agent-7 (t4g.xlarge) / jwu-macbook |
| Skills | code, review |
| Model | opus |
| Duration | 12m |
| Cost | $2.34 |
| SSH | `agent-7` (copyable) |

**Filters**: status, resource type (EC2 / device), skill, model
**Actions**: stop agent, open in Linear, copy SSH command
**Refresh**: every 5s.

### `/agents/:id` — Agent Detail

| Section | Content |
|---|---|
| Header | Agent ID, status badge, task title, Linear link |
| Resource | Instance type, Tailscale hostname, region, uptime |
| Skills | Assigned skills with descriptions |
| Git | Branch, commit history, PR link |
| Cost | Compute cost, API cost, total, budget remaining |
| Timeline | Chronological events: started, progress updates, errors, completed |
| Logs | Recent Claude Code output (last 100 lines) |

**Actions**: stop, restart, open SSH (link to `ssh://agent-7`), view in Linear, view PR
**Refresh**: every 5s.

### `/tasks` — Task List

| Column | Example |
|---|---|
| ID | #42 |
| Job | Fix login validation |
| Status | queued / running / completed |
| Resource | agent-7 / jwu-macbook / (unassigned) |
| Routing | ec2 / laptop / auto |
| Attempts | 1/3 |
| Created | 2m ago |

**Filters**: status, routing, resource
**Actions**: re-route task, cancel task, retry task
**Refresh**: every 5s.

### `/terminals` — Terminal Sessions

Lists all active Zellij sessions across all resources.

| Column | Example |
|---|---|
| Resource | agent-7 |
| Session | agent-7-main |
| Tabs | claude, shell, git |
| Agent | #7 |
| Status | active |

**Actions**: copy SSH + attach command
**No embedded web terminal** — SSH via Tailscale directly. You already know the hostname.

```bash
# Copy this from the dashboard and paste in terminal:
ssh agent-7 -t "zellij attach agent-7-main"
```

Future consideration: a web terminal could be added via a small WebSocket relay service, but it's not needed when Tailscale SSH is one command away.

### `/resources` — Resource List

| Column | Example |
|---|---|
| Name | agent-7 / jwu-macbook |
| Type | EC2 / device |
| Status | running / online / offline / terminated |
| Instance type | t4g.xlarge / — |
| Tailscale IP | 100.x.y.z |
| Active sessions | 2 |
| Last heartbeat | 15s ago |
| Uptime / Online since | 45m |

**Filters**: type (EC2 / device), status
**Actions**: terminate (EC2), view sessions
**Refresh**: every 10s.

### `/resources/:id` — Resource Detail

| Section | Content |
|---|---|
| Header | Name, type, status, Tailscale hostname |
| EC2 info | Instance ID, type, AMI, spot/on-demand, launch time |
| Device info | Owner, capabilities, last heartbeat, online/offline history |
| Sessions | Active and past Claude Code sessions on this resource |
| Terminals | Zellij sessions and tabs |
| Costs | Compute costs attributed to this resource |

### `/spawn` — Manual Spawn

Form to manually spawn an agent:

| Field | Type | Options |
|---|---|---|
| Linear issue | Text (URL or ID) | Required |
| Skills | Multi-select | plan, code, review, bench, research, explore |
| Model | Select | sonnet (default), opus, haiku |
| Resource | Select | Auto, EC2 (small/large/bench), personal device list |
| Max budget | Number | Optional, USD |

Submit → calls POST `/api/spawn` → redirects to `/agents/:id`.

### `/costs` — Cost Dashboard

| Section | Content |
|---|---|
| Today | Total spend, breakdown by type (compute, API) |
| This week | Daily chart, running total |
| This month | Weekly chart, running total |
| By agent | Top agents by cost |
| By resource | Cost per resource type |
| Budget status | Per-job budgets, daily cap, global cap with progress bars |

**Refresh**: every 30s.

## Data Fetching

Using SWR for all API calls:

```typescript
import useSWR from 'swr';

const fetcher = (url: string) => fetch(url).then(r => r.json());

function useAgents() {
  return useSWR('/api/agents', fetcher, {
    refreshInterval: 5000,  // 5s for agent list
  });
}

function useCosts() {
  return useSWR('/api/costs', fetcher, {
    refreshInterval: 30000, // 30s for costs
  });
}

function useAgent(id: string) {
  return useSWR(`/api/agents/${id}`, fetcher, {
    refreshInterval: 5000,  // 5s for agent detail
  });
}

function useResources() {
  return useSWR('/api/resources', fetcher, {
    refreshInterval: 10000, // 10s for resource list
  });
}
```

## Responsive Design

The dashboard supports iPad Safari (for monitoring agents from an iPad + Blink SSH):

- Responsive grid layouts
- Touch-friendly action buttons
- Copyable SSH commands (tap to copy)
- No hover-dependent interactions
