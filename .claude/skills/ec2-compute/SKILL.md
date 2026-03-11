---
name: ec2-compute
description: Launch and manage EC2 instances for remote compute. Reuse idle instances, run commands via SSH over Tailscale.
---

# EC2 Remote Compute

You can launch, manage, and run commands on EC2 instances for tasks that need
more compute than the local machine (Mac Air). Always prefer reusing an idle
instance over launching a new one.

## Networking: Tailscale SSH

All EC2 instances automatically join the Tailscale mesh network on boot. This
means:

- **SSH by hostname**: `ssh agent-1` works immediately — no IP addresses needed
- **No SSH keys**: Tailscale SSH handles authentication, no key management
- **Private subnet**: Instances have no public IP. They are ONLY reachable via Tailscale
- **Automatic cleanup**: Instances use ephemeral Tailscale auth keys, so they are removed from the tailnet when terminated

How it works under the hood:
1. `launch.sh` generates a Tailscale ephemeral auth key via the Tailscale API
2. The instance installs Tailscale during boot and joins the tailnet with `--ssh`
3. MagicDNS registers the hostname (e.g. `agent-1`) on the tailnet
4. The launch script polls `tailscale status` until the instance appears (~3-5 min)
5. Once ready, `ssh <hostname>` just works

If SSH fails after launch, run `tailscale status` to check if the device has joined the tailnet.

## Core workflow

### Step 1: Check for existing instances FIRST

Before launching anything, always check what's already running:

```bash
./scripts/status.sh
```

Output shows each instance with CPU, RAM, uptime, and status:
```
INSTANCES:

  agent-1        t3.xlarge      i-0abc123  CPU: 0.12   RAM: 1200/16000 MB  up 2 hours   IDLE
  agent-2        c7i.2xlarge    i-0def456  CPU: 6.80   RAM: 12000/16000 MB up 30 minutes BUSY

  Idle: 1  |  Busy: 1  |  Total: 2  |  Cost: ~$0.523/hr
```

### Step 2: Decide — reuse or launch

- **Idle instance available?** Use it. `ssh agent-1 "command"`
- **All busy?** Launch a new one. `./scripts/launch.sh --name agent-3`
- **No instances at all?** Launch one. `./scripts/launch.sh --name agent-1`
- **Need more compute?** Launch a bigger type. `./scripts/launch.sh --name agent-3 --type c7i.2xlarge`

### Step 3: Run commands

```bash
# Single command
ssh agent-1 "cd /home/ubuntu/repo && cargo build --release"

# Multiple commands
ssh agent-1 "cd /home/ubuntu/repo && cargo test 2>&1"

# Long-running (use nohup or run in background)
ssh agent-1 "cd /home/ubuntu/repo && nohup cargo bench > bench.log 2>&1 &"

# Check on a background job
ssh agent-1 "tail -50 /home/ubuntu/repo/bench.log"
```

### Step 4: Monitor during long tasks

```bash
# Quick health check
ssh agent-1 "uptime && free -h"

# What's consuming resources
ssh agent-1 "ps aux --sort=-%cpu | head -10"

# Disk usage
ssh agent-1 "df -h /"
```

### Step 5: Terminate only when explicitly asked

Do NOT auto-terminate after commands. Instances take 3-5 minutes to boot.
Only terminate when:
- User says "tear down" / "terminate" / "shut down"
- End of work session
- Instance has been idle for a long time

```bash
./scripts/terminate.sh --name agent-1
# Or terminate all:
./scripts/terminate.sh --all
```

## Setting up a repo on an instance

```bash
# Clone
ssh agent-1 "git clone https://github.com/org/repo.git"

# Or clone a specific branch/PR
ssh agent-1 "git clone https://github.com/org/repo.git && cd repo && git fetch origin pull/98/head:pr-98 && git checkout pr-98"

# Install dependencies (Rust project)
ssh agent-1 "cd repo && cargo build"
```

GitHub is already authenticated on instances via 1Password (github-token).

## Available instance types

All instances are **x86_64 (Intel)** running Ubuntu 22.04.

| Type | vCPUs | RAM | $/hr | Best for |
|---|---|---|---|---|
| t3.medium | 2 | 4 GB | $0.042 | Light tasks, quick checks |
| t3.large | 2 | 8 GB | $0.083 | Medium compile jobs |
| t3.xlarge | 4 | 16 GB | $0.166 | Standard dev work (default) |
| c7i.2xlarge | 8 | 16 GB | $0.357 | Benchmarks, heavy builds |

Pick based on the task:
- Quick fix / single file compile -> t3.medium
- Full cargo build of a large project -> t3.xlarge
- Benchmarks or parallel compilation -> c7i.2xlarge

## Cost awareness

- Instances cost money per hour even when idle
- Prefer reusing idle instances over launching new ones
- Run `./scripts/status.sh` to see total hourly cost
- Mention cost when launching: "Launching t3.xlarge (~$0.17/hr)"
- If multiple instances are idle, suggest terminating extras

## Important notes

- All instances are **x86_64 (Intel)**. The local machine may be ARM (Mac), so compiled artifacts are NOT cross-compatible.
- Instances are in a private subnet — only reachable via Tailscale SSH.
- bootstrap.sh installs: Rust, Node.js 22, Python 3, Claude Code, Zed, Zellij, ripgrep, fd, bat, git, gh CLI, 1Password CLI.
- The ubuntu user home is /home/ubuntu.
- SSH uses Tailscale SSH — no key management needed. Just `ssh <hostname>`.
