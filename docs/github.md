# GitHub Integration

> How agents authenticate with GitHub, push code, create PRs, handle reviews, and use the GitHub API.

## Authentication

A single GitHub token covers all git and GitHub operations. Two options:

### Option A: Personal Access Token (PAT)

Fine-grained PAT with `repo` scope. Simplest for a single-user setup.

```bash
# Generate at: https://github.com/settings/tokens?type=beta
# Required permissions:
#   - Repository access: All repositories (or specific repos)
#   - Contents: Read and write
#   - Pull requests: Read and write
#   - Issues: Read and write (for cross-referencing)
#   - Metadata: Read
```

### Option B: GitHub App Installation Token

Better for team setups. The app creates short-lived tokens per agent.

```typescript
import { createAppAuth } from '@octokit/auth-app';

const auth = createAppAuth({
  appId: GITHUB_APP_ID,
  privateKey: GITHUB_APP_PRIVATE_KEY,
  installationId: GITHUB_INSTALLATION_ID,
});

const { token } = await auth({ type: 'installation' });
// token is short-lived (1 hour), scoped to the installation
```

### Token storage

| Environment | Where |
|---|---|
| EC2 agent | AWS Secrets Manager (`agent/github-token`) |
| Personal device | Local `.env` (`GITHUB_TOKEN=ghp_xxx`) |
| App (Vercel) | Environment variable |

## Git Operations

### Configure HTTPS auth

```bash
# Set token for all github.com HTTPS URLs
git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
```

This lets `git clone`, `git push`, etc. work without SSH keys.

### Clone

```bash
git clone https://github.com/org/repo.git
# Token is injected automatically via the git config above
```

### Branch naming

Agents create branches with a consistent naming convention:

```
agent-{agentId}/{issue-slug}
```

Examples:
```
agent-7/fix-login-validation
agent-12/add-dark-mode
agent-3/perf-benchmark-results
```

### Push

```bash
git checkout -b agent-7/fix-login-validation
# ... make changes ...
git add -A
git commit -m "Fix login validation — accept only non-empty passwords

Fixes LINEAR-123"
git push -u origin agent-7/fix-login-validation
```

### Create PR

```bash
gh pr create \
  --title "Fix login validation" \
  --body "Fixes LINEAR-123

## Changes
- Added password length check in \`src/auth/validate.ts\`
- Added tests for empty/short password cases

## Testing
- All existing tests pass
- Added 3 new test cases" \
  --base main
```

## GitHub CLI (`gh`)

The GitHub CLI is authenticated with the same token:

```bash
echo "${GITHUB_TOKEN}" | gh auth login --with-token
```

### Common agent operations

```bash
# Create PR
gh pr create --title "..." --body "..."

# List open PRs
gh pr list

# View PR details
gh pr view 42

# Comment on a PR
gh pr comment 42 --body "Fixed the null check as requested."

# Request review
gh pr edit 42 --add-reviewer username

# Merge PR (if agent has permission)
gh pr merge 42 --squash --delete-branch

# Check CI status
gh pr checks 42

# View PR diff
gh pr diff 42
```

## GitHub REST API

For operations the `gh` CLI doesn't cover, use the REST API directly.

### List PR comments

```typescript
const response = await fetch(
  'https://api.github.com/repos/org/repo/pulls/42/comments',
  {
    headers: {
      'Authorization': `Bearer ${GITHUB_TOKEN}`,
      'Accept': 'application/vnd.github.v3+json',
    },
  }
);
const comments = await response.json();
```

### Create a PR review comment (inline on code)

```typescript
await fetch('https://api.github.com/repos/org/repo/pulls/42/comments', {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${GITHUB_TOKEN}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    body: 'This should handle the null case.',
    commit_id: 'abc123',
    path: 'src/auth/validate.ts',
    line: 42,
    side: 'RIGHT',
  }),
});
```

### Submit a PR review

```typescript
await fetch('https://api.github.com/repos/org/repo/pulls/42/reviews', {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${GITHUB_TOKEN}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    event: 'APPROVE',  // or 'REQUEST_CHANGES', 'COMMENT'
    body: 'Looks good! All edge cases handled.',
  }),
});
```

### Get PR details

```typescript
const pr = await fetch('https://api.github.com/repos/org/repo/pulls/42', {
  headers: {
    'Authorization': `Bearer ${GITHUB_TOKEN}`,
    'Accept': 'application/vnd.github.v3+json',
  },
}).then(r => r.json());

// pr.state, pr.title, pr.body, pr.head.ref, pr.mergeable, pr.additions, pr.deletions
```

### List check runs on a PR

```typescript
const checks = await fetch(
  `https://api.github.com/repos/org/repo/commits/${sha}/check-runs`,
  {
    headers: {
      'Authorization': `Bearer ${GITHUB_TOKEN}`,
      'Accept': 'application/vnd.github.v3+json',
    },
  }
).then(r => r.json());

// checks.check_runs[].name, .status, .conclusion
```

### Create a commit status

```typescript
await fetch(`https://api.github.com/repos/org/repo/statuses/${sha}`, {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${GITHUB_TOKEN}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    state: 'success',  // 'pending', 'success', 'failure', 'error'
    description: 'Agent #7 completed',
    context: 'agent-army',
    target_url: 'https://dashboard.example.com/agents/7',
  }),
});
```

## GitHub Webhooks

The app subscribes to GitHub webhooks to route PR feedback to agents.

### Webhook events

| Event | Purpose |
|---|---|
| `pull_request_review` | PR approved or changes requested |
| `pull_request_review_comment` | Inline code review comment |
| `issue_comment` | Comment on PR (PRs are issues in GitHub) |
| `check_suite` | CI checks completed |

### Webhook handler

```typescript
app.post('/api/webhooks/github', async (req, reply) => {
  const event = req.headers['x-github-event'];
  const payload = req.body;

  switch (event) {
    case 'pull_request_review':
      await handlePrReview(payload);
      break;

    case 'pull_request_review_comment':
      await handleReviewComment(payload);
      break;

    case 'issue_comment':
      if (payload.issue.pull_request) {
        await handlePrComment(payload);
      }
      break;

    case 'check_suite':
      await handleCheckSuite(payload);
      break;
  }

  reply.status(200).send({ ok: true });
});
```

### Routing PR feedback to agents

```typescript
async function handleReviewComment(payload: PrReviewCommentPayload) {
  const { comment, pull_request } = payload;

  // Find the agent that created this PR
  const session = await db.claude_sessions.findByBranch(
    pull_request.head.ref  // e.g., "agent-7/fix-login-bug"
  );

  if (!session || session.status !== 'running') return;

  // Forward the review comment to the agent
  await forwardToAgent(session, {
    type: 'pr_review_comment',
    from: comment.user.login,
    body: comment.body,
    path: comment.path,
    line: comment.line,
    diff_hunk: comment.diff_hunk,
  });
}

async function handleCheckSuite(payload: CheckSuitePayload) {
  const { check_suite } = payload;

  if (check_suite.conclusion === 'failure') {
    // Find agent for this branch
    const branch = check_suite.head_branch;
    const session = await db.claude_sessions.findByBranch(branch);

    if (session && session.status === 'running') {
      await forwardToAgent(session, {
        type: 'ci_failure',
        branch,
        conclusion: check_suite.conclusion,
        url: check_suite.url,
      });
    }
  }
}
```

## End-to-End PR Workflow

```
1. Agent creates branch: agent-7/fix-login-bug
2. Agent pushes code
3. Agent creates PR via `gh pr create`
4. CI runs → check_suite webhook → forwarded to agent if it fails
5. Human reviews → pull_request_review webhook → forwarded to agent
6. Agent reads review, pushes fixes
7. Human approves → agent reports complete
8. PR merged (manually or by agent if configured)
```

## Using Octokit (TypeScript SDK)

For the app server (not agents), use Octokit for GitHub API calls:

```typescript
import { Octokit } from '@octokit/rest';

const octokit = new Octokit({ auth: GITHUB_TOKEN });

// List PRs by an agent
const { data: prs } = await octokit.pulls.list({
  owner: 'org',
  repo: 'repo',
  head: 'org:agent-7/fix-login-bug',
  state: 'open',
});

// Get PR review comments
const { data: comments } = await octokit.pulls.listReviewComments({
  owner: 'org',
  repo: 'repo',
  pull_number: 42,
});

// Create a commit comment
await octokit.repos.createCommitComment({
  owner: 'org',
  repo: 'repo',
  commit_sha: 'abc123',
  body: 'Agent #7: Fixed the issue found in review.',
});
```
