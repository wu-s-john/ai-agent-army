---
name: linear-agent-session
description: Use when a Codex session is driven by Linear issues, Linear comments, Hermes webhooks, or agent-session metadata. Covers standard Linear status comments, start/resume behavior, message normalization, locking, and when to use Linear MCP versus deterministic webhook code.
---

# Linear Agent Session

## Overview

Use this skill when Codex is acting as an agent for a Linear issue or when building the Hermes/OpenClaw bridge that starts or resumes Codex from Linear webhooks.

This skill does not replace the Linear MCP server. Use the `linear` skill and Linear MCP tools for in-session Linear reads/writes. Use deterministic Hermes/webhook code for signature verification, routing, locking, queueing, and `codex exec` process management.

## Operating Model

Linear is the task control plane. Hermes or another orchestrator owns webhook intake, session lookup, locks, and process execution. Codex owns the actual work and may use Linear MCP for issue context and comments while working.

```text
Linear issue/comment
  -> Hermes webhook handler
  -> agent session lookup + lock
  -> codex exec / codex exec resume
  -> Codex uses Linear MCP as needed
  -> Linear status/comment update
```

## Session Metadata

Every active Linear-driven Codex task should have durable metadata outside the Codex thread:

```text
linear_issue_id
linear_issue_identifier
linear_issue_url
codex_thread_id
cwd
repo_url
branch
status
worker_device
locked_at
last_linear_comment_id
slack_channel_id
slack_thread_ts
```

Treat `codex_thread_id` as the Codex memory pointer, not as the whole source of truth. The orchestrator must still track issue id, repo/cwd, lock state, and delivery cursors.

## Linear Comments From Codex

When asked to comment or update Linear from inside Codex:

1. Use the `linear` skill and Linear MCP tools.
2. Prefer a single concise comment for start, blocker, major milestone, and final result.
3. Do not post frequent progress chatter.
4. Include links humans need: branch, PR, Slack control thread, dashboard, or failing check.
5. Never include secrets, full environment dumps, auth tokens, or noisy logs.

### Comment Shapes

Start:

```text
Agent started.

Branch: <branch>
Workspace: <worker/cwd summary>
Control: <Slack thread or dashboard link if available>
```

Blocked:

```text
Blocked: <short reason>

I need: <one clear ask>
Context: <one or two useful facts>
```

Final:

```text
Done: <one-sentence outcome>

Changed: <short list of important files/behavior>
Verified: <tests/checks run, or say not run>
PR: <link if available>
```

## Inbound Message Normalization

Messages delivered to Codex from Linear should be explicit about source and issue:

```text
[Linear LIN-123 from Alice]
<comment body>

Issue: <title>
URL: <linear issue url>
```

If several comments arrive while Codex is running, queue them and deliver them in creation order after the active `codex exec resume` finishes.

## Start And Resume

For a new Linear issue with no existing Codex thread, the orchestrator should start a persisted non-ephemeral Codex run:

```bash
codex exec -C "$CWD" --json "$INITIAL_PROMPT"
```

Capture the created Codex thread id from the JSON event stream, then store it in session metadata. Do not use `--ephemeral` for Linear-driven work.

For an existing issue/session, resume the stored thread:

```bash
printf '%s\n' "$NORMALIZED_MESSAGE" \
  | codex exec -C "$CWD" resume --json "$CODEX_THREAD_ID" -
```

Only one process may resume a given `codex_thread_id` at a time. Use a lock keyed by Linear issue id or Codex thread id.

For Hermes code, prefer invoking [scripts/codex-linear-run.sh](scripts/codex-linear-run.sh) so the initial prompt and resume message shape stay consistent.

## Control Comments

Use deterministic parsing in Hermes for control comments before involving Codex:

```text
@agent code this       -> create/resume session
@agent plan this       -> create/resume in planning mode
@agent stop            -> stop or mark paused
@agent restart         -> start a fresh Codex thread and preserve old thread id in metadata
@agent approved        -> resume after waiting for approval
```

Unrecognized human comments on an active issue should be forwarded to Codex as feedback.

## Hermes Webhook Work

When implementing or reviewing the Hermes webhook path, read [references/hermes-webhook.md](references/hermes-webhook.md).

That reference covers:

- Linear webhook verification
- event classification
- session locking and queueing
- starting/resuming Codex
- required Linear GraphQL/MCP operations
- failure handling

For required secrets and 1Password field names, read [references/credentials.md](references/credentials.md).

## Boundaries

Do not rely on the LLM to verify webhook signatures, deduplicate events, hold locks, or choose whether to run shell processes. Those are deterministic orchestrator responsibilities.

Do not rely on Slack or Linear comments as the only state store. They are human-visible logs; the orchestrator database is the machine state.
