# Linear Agent Credentials

Use these credential names for Linear-driven Codex sessions.

## 1Password Fields

Vault:

```text
ai-agent-army
```

Items and fields:

```text
op://ai-agent-army/Linear/linear_api_key
op://ai-agent-army/Linear/linear_webhook_url
op://ai-agent-army/Linear/linear_webhook_signing_secret
op://ai-agent-army/Hermes/ingress_token
```

## Environment Variables

These are injected by `./secrets.sh` from `dotfiles/env-secrets.sh.tmpl`:

```bash
LINEAR_API_KEY
LINEAR_WEBHOOK_URL
LINEAR_WEBHOOK_SECRET
HERMES_INGRESS_TOKEN
```

## Purpose

`LINEAR_API_KEY` is used for outbound Linear API calls, such as comments and issue updates, from Hermes or the EC2 webhook gateway if needed.

`LINEAR_WEBHOOK_URL` is the public URL configured in Linear's webhook settings.

`LINEAR_WEBHOOK_SECRET` is configured in Linear's webhook settings and copied into 1Password as `linear_webhook_signing_secret`. The EC2 webhook gateway uses it to verify `Linear-Signature`.

`HERMES_INGRESS_TOKEN` is an internal bearer token. The EC2 webhook gateway sends it to Hermes over Tailscale, and Hermes rejects requests without it.

## Generate Random Secrets

Generate the two shared secrets locally:

```bash
openssl rand -hex 32  # LINEAR_WEBHOOK_SECRET
openssl rand -hex 32  # HERMES_INGRESS_TOKEN
```

Do not paste these into Codex prompts or commit them to the repo.

## Linear API Key

Create the Linear API credential from Linear's workspace settings or developer settings. Store the resulting value in:

```text
op://ai-agent-army/Linear/linear_api_key
```

If the EC2 webhook gateway only verifies and forwards events, it does not need `LINEAR_API_KEY`; Hermes can own outbound Linear writes instead.
