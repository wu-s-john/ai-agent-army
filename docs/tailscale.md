# Tailscale Networking

> Every agent — EC2 or personal device — joins a Tailscale mesh network for SSH access, MagicDNS, and secure communication.

## Overview

Tailscale creates a WireGuard-based mesh VPN. Every agent gets a stable DNS name (e.g., `agent-7`) and is reachable via Tailscale SSH — no SSH key management, no port forwarding, no public IPs needed.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Your Mac   │     │  EC2 agent  │     │  Your iPad  │
│ (Tailscale) │◀───▶│ (Tailscale) │◀───▶│  (Blink)    │
└──────┬──────┘     └──────┬──────┘     └─────────────┘
       │                   │
       ▼                   ▼
  ┌─────────────────────────────┐
  │   Tailscale Coordination   │
  │   (DERP relay + control)   │
  └─────────────────────────────┘
```

All traffic is peer-to-peer (WireGuard direct). DERP relays are only used when NAT traversal fails.

## MagicDNS

Every device on the tailnet gets a DNS name:

```
agent-7.tailnet-name.ts.net     (full FQDN)
agent-7                          (short name, via MagicDNS)
jwu-macbook                      (personal device name)
```

SSH is as simple as:

```bash
ssh agent-7                    # EC2 agent
ssh jwu-macbook                # personal device
```

## Auth Key Generation

EC2 agents join the tailnet automatically during bootstrap using pre-generated auth keys.

### Via API (app generates keys for each agent)

```typescript
const response = await fetch('https://api.tailscale.com/api/v2/tailnet/-/keys', {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${TAILSCALE_API_KEY}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    capabilities: {
      devices: {
        create: {
          reusable: false,
          ephemeral: true,        // auto-removed when instance terminates
          preauthorized: true,    // no manual approval needed
          tags: ['tag:agent'],    // for ACL rules
        },
      },
    },
    expirySeconds: 3600,         // 1 hour (only needs to last through bootstrap)
  }),
});

const { key } = await response.json();
// key = "tskey-auth-xxxxx"
// Pass this to the EC2 instance via user-data or Secrets Manager
```

### Key properties

| Property | Value | Why |
|---|---|---|
| `ephemeral` | `true` | Auto-removed from tailnet when instance terminates |
| `preauthorized` | `true` | No manual approval in Tailscale admin |
| `reusable` | `false` | One-time use per instance |
| `tags` | `['tag:agent']` | For ACL rules (agents vs members) |
| `expirySeconds` | `3600` | Key expires after 1 hour |

## CLI Commands

### Install (Ubuntu, used in bootstrap.sh)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

### Join tailnet

```bash
# EC2 agent (ephemeral, auto-removed on termination)
sudo tailscale up \
  --authkey="${TAILSCALE_AUTH_KEY}" \
  --hostname="agent-${AGENT_ID}" \
  --ssh

# Personal device (persistent, one-time setup)
sudo tailscale up --hostname="jwu-macbook" --ssh
```

### Status and diagnostics

```bash
tailscale status          # List all devices on tailnet
tailscale ip              # Show this device's Tailscale IP
tailscale ping agent-7    # Test connectivity to an agent
tailscale netcheck        # Network diagnostics (NAT type, DERP latency)
```

### Disconnect

```bash
tailscale down            # Disconnect (keep config)
tailscale logout          # Full logout (remove from tailnet)
```

## API Commands

### List devices

```bash
curl -s "https://api.tailscale.com/api/v2/tailnet/-/devices" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}" | jq '.devices[] | {name, id, online}'
```

### Get device

```bash
curl -s "https://api.tailscale.com/api/v2/device/${DEVICE_ID}" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}" | jq '{name, addresses, online, lastSeen}'
```

### Delete device

```bash
curl -X DELETE "https://api.tailscale.com/api/v2/device/${DEVICE_ID}" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}"
```

## ACL Policy

Access control rules for the tailnet:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["group:members"],
      "dst": ["tag:agent:*"],
      "comment": "Members can SSH to any agent"
    },
    {
      "action": "accept",
      "src": ["tag:agent"],
      "dst": ["autogroup:internet:*"],
      "comment": "Agents can reach the internet (GitHub, npm, APIs)"
    }
  ],

  "groups": {
    "group:members": ["user@example.com"]
  },

  "tagOwners": {
    "tag:agent": ["group:members"]
  },

  "ssh": [
    {
      "action": "accept",
      "src": ["group:members"],
      "dst": ["tag:agent"],
      "users": ["ubuntu", "root"],
      "comment": "Members can SSH to agents as ubuntu or root"
    }
  ]
}
```

### What this means

| From | To | Allowed |
|---|---|---|
| Members (you) | Any agent | Yes (SSH + any port) |
| Agents | Internet | Yes (GitHub, npm, APIs) |
| Agent → Agent | Another agent | **No** (isolated by default) |
| Internet → Agent | Any agent | **No** (no public exposure) |

Agent-to-agent communication goes through the app's API, not direct connections.

## Tailscale SSH

Tailscale SSH eliminates SSH key management entirely:

- No `~/.ssh/authorized_keys` on agents
- No SSH keypairs to generate, distribute, or rotate
- Authentication via Tailscale identity (your Tailscale login)
- Access controlled by ACL rules above

```bash
# Just works — no keys needed
ssh agent-7
ssh ubuntu@agent-7
ssh jwu-macbook
```

## Bootstrap Snippet

Added to bootstrap.sh after the base setup:

```bash
# ─── Tailscale ───
echo "=== Installing Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sh

# TAILSCALE_AUTH_KEY and AGENT_ID are injected via user-data or Secrets Manager
sudo tailscale up \
  --authkey="${TAILSCALE_AUTH_KEY}" \
  --hostname="agent-${AGENT_ID}" \
  --ssh

echo "Tailscale IP: $(tailscale ip -4)"
echo "Hostname: agent-${AGENT_ID}"
```

## Connecting from Clients

### From Mac (Terminal / iTerm2)

```bash
ssh agent-7                              # Tailscale SSH
ssh ubuntu@agent-7 -t "zellij attach"   # Attach to agent's Zellij session
```

### From Mac (Zed editor)

```
Cmd+Shift+P → "Remote: Connect to Host"
Host: agent-7
```

Full IDE experience connected to the agent — edit files, see terminal, run commands.

### From Mac (VS Code)

```
Cmd+Shift+P → "Remote-SSH: Connect to Host"
Host: agent-7
```

### From iPad (Blink Shell)

```bash
ssh agent-7
# Zellij works great in Blink — full terminal multiplexer experience
zellij attach
```

## Cleanup

### Ephemeral auto-removal

EC2 agents use ephemeral auth keys. When the instance terminates:
1. Tailscale client disconnects
2. After a timeout (~5 minutes), Tailscale removes the device from the tailnet
3. No manual cleanup needed

### Manual removal (if needed)

```bash
# Via API
curl -X DELETE "https://api.tailscale.com/api/v2/device/${DEVICE_ID}" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}"

# Via admin console
# https://login.tailscale.com/admin/machines → delete device
```

### App cleanup job

The app runs a periodic cleanup to catch any orphaned devices:

```typescript
async function cleanupOrphanedDevices() {
  const tailscaleDevices = await listTailscaleDevices();
  const activeResources = await db.resources.findActive();

  for (const device of tailscaleDevices) {
    if (device.name.startsWith('agent-')) {
      const resource = activeResources.find(r => r.tailscale_name === device.name);
      if (!resource) {
        await deleteTailscaleDevice(device.id);
      }
    }
  }
}
```

## Tailnet Naming

Rename the tailnet for branding:

```
Default: username.github.ts.net
Renamed: agent-army.ts.net

agent-7.agent-army.ts.net → short: agent-7
```

Configure at: https://login.tailscale.com/admin/dns → Rename tailnet
