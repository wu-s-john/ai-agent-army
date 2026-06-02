# Hermes Linear Webhook Contract

Use this reference when implementing or reviewing the Hermes/OpenClaw path that receives Linear webhooks and starts or resumes Codex.

## Components

```text
Linear
  sends signed webhook events

Hermes webhook route
  verifies signature
  classifies event
  queues work

Orchestrator store
  owns session metadata, locks, cursors, and idempotency

Codex runner
  runs codex exec / codex exec resume
  streams JSON events

Linear MCP or GraphQL
  posts comments and status updates
```

Hermes may be the HTTP host and routing layer. The critical side effects should live in narrow deterministic tools or handlers.

## Webhook Intake

Endpoint:

```text
POST /webhooks/linear
```

Required checks:

```text
1. Read the raw request body exactly as received.
2. Verify Linear-Signature with the configured webhook secret.
3. Reject stale timestamps from the payload's webhookTimestamp.
4. Deduplicate by Linear webhook event id when available, otherwise by event type + object id + updated timestamp.
5. Ignore events authored by the agent/bot integration.
```

Subscribe to:

```text
Issue update
Comment create
```

Useful triggers:

```text
agent label added      -> activate session
agent label removed    -> stop/pause session
@agent comment         -> command or feedback
ordinary comment       -> feedback if issue has active session
```

## Event Classification

Classify before calling Codex:

```text
activate
  Issue got the agent label, or comment says @agent code/plan/review/bench/research.

feedback
  Human comment on an active agent issue that is not a control command.

control
  stop, restart, approved, use model, route to device/ec2, pause.

ignore
  bot-authored comments, duplicate webhook events, unrelated issues.
```

## Session Table

Minimum fields:

```sql
linear_issue_id TEXT PRIMARY KEY,
linear_issue_identifier TEXT NOT NULL,
linear_issue_url TEXT,
codex_thread_id TEXT,
cwd TEXT NOT NULL,
repo_url TEXT,
branch TEXT,
status TEXT NOT NULL,
worker_device TEXT,
locked_at TIMESTAMPTZ,
last_linear_comment_id TEXT,
last_slack_ts TEXT,
metadata JSONB DEFAULT '{}'
```

Use a separate queue table if multiple comments may arrive while a run is active:

```sql
agent_messages (
  id,
  linear_issue_id,
  source,
  sender,
  body,
  source_message_id,
  delivered,
  created_at,
  metadata
)
```

Add unique constraints for source idempotency, for example `(source, source_message_id)`.

## Locking

Before starting or resuming Codex:

```text
1. Acquire a row lock or advisory lock for linear_issue_id/codex_thread_id.
2. If locked, enqueue the inbound message and return 200 to Linear.
3. If lock is stale, mark the old run interrupted before taking over.
4. Release the lock only after Codex exits and output has been recorded.
5. Drain queued messages in order before marking idle.
```

Never run two `codex exec resume` processes against the same `codex_thread_id` concurrently.

## Starting Codex

When there is no session:

```bash
codex exec -C "$CWD" --json "$INITIAL_PROMPT"
```

Initial prompt should include:

```text
You are working on Linear issue <identifier>: <title>.
URL: <url>
Description:
<description>

Use the linear-agent-session workflow. Keep Linear updated at start, blocker, and final result.
Create/use branch <branch> if code changes are needed.
```

Capture and store:

```text
codex_thread_id
branch
worker_device
started_at
```

The JSON stream should be parsed for thread/start information and final assistant output. If the exact field name changes across Codex versions, isolate that parser behind one helper and add a fixture test.

## Resuming Codex

For each queued message:

```bash
printf '%s\n' "$NORMALIZED_MESSAGE" \
  | codex exec -C "$CWD" resume --json "$CODEX_THREAD_ID" -
```

Normalized message:

```text
[Linear <identifier> from <display name>]
<comment body>

Issue: <title>
URL: <url>
```

Use `--json` so Hermes can stream progress to logs, dashboards, Linear, or Slack.

The bundled helper script wraps both start and resume:

```bash
SKILL_DIR=/Users/johnwu/code/ai-agent-army/claude/skills/linear-agent-session

"$SKILL_DIR/scripts/codex-linear-run.sh" start \
  --cwd "$CWD" \
  --issue "$IDENTIFIER" \
  --title "$TITLE" \
  --url "$URL" \
  --branch "$BRANCH" \
  --description-file "$DESCRIPTION_FILE"

"$SKILL_DIR/scripts/codex-linear-run.sh" resume \
  --cwd "$CWD" \
  --thread-id "$CODEX_THREAD_ID" \
  --issue "$IDENTIFIER" \
  --sender "$SENDER" \
  --title "$TITLE" \
  --url "$URL" \
  --message-file "$MESSAGE_FILE"
```

## Linear Operations

You can use either direct Linear GraphQL from Hermes or Linear MCP from Codex. Prefer direct GraphQL for deterministic orchestration. Prefer Linear MCP when Codex needs to inspect context or write a task-aware comment during its own work.

Common GraphQL operations for Hermes:

```graphql
query IssueForAgent($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    description
    url
    labels { nodes { id name } }
    state { id name }
    assignee { id name }
    team { id key name }
  }
}
```

```graphql
mutation CommentCreate($input: CommentCreateInput!) {
  commentCreate(input: $input) {
    success
    comment { id url body createdAt }
  }
}
```

```graphql
mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) {
    success
    issue { id identifier title url }
  }
}
```

MCP operations Codex may use through the Linear skill:

```text
list recent tickets
get issue comments
add comment to issue
update issue fields
resolve comment
```

## Status Updates

On activation:

```text
Agent started.

Thread: <codex_thread_id>
Worker: <worker_device>
Branch: <branch>
```

On blocked:

```text
Blocked: <short reason>

I need: <specific human input>
```

On completion:

```text
Done: <short result>

PR: <link if any>
Verified: <tests/checks>
```

## Failure Handling

Codex process exits non-zero:

```text
1. Store stderr/stdout summary in run logs.
2. Mark session status failed or waiting depending on error.
3. Comment in Linear with a concise failure summary and next action.
4. Keep codex_thread_id unless restart was explicitly requested.
```

Linear API/MCP write fails:

```text
1. Do not retry in a tight loop.
2. Store pending outbound update.
3. Mark delivery failure for operator attention.
```

Missing Codex thread on worker:

```text
1. If device-pinned, route back to original worker.
2. If migration is supported, restore/sync Codex state first.
3. Otherwise start a fresh thread and include the old thread id and issue context in the initial prompt.
```

## Security Notes

Do not pass Linear API tokens, webhook secrets, Slack tokens, or 1Password output into Codex prompts.

Do not allow arbitrary Linear comments to become shell commands. Comments are user instructions to Codex, still subject to Codex approval and sandbox policy.

Use per-session callback tokens if Codex reports progress back to Hermes through an API.
