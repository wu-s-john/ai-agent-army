---
name: address-reviews
description: Iteratively addresses PR review comments from @claude and/or a subagent reviewer. Fixes valid feedback, debates invalid feedback, and triggers re-review. Designed for `/loop` polling.
tools: Read, Grep, Glob, Bash, Edit, Write, Agent
---

# Address Reviews

Automatically address unresolved review comments on a pull request. Collects feedback from two sources — `@claude` GitHub review comments and an independent subagent reviewer — then fixes or debates each concern.

## Usage

```
/address-reviews <PR#>
/address-reviews <PR#> --reviewer claude     # only @claude comments
/address-reviews <PR#> --reviewer subagent   # only subagent review
/address-reviews <PR#> --reviewer both       # default: both sources
```

For continuous polling:
```
/loop 2m /address-reviews <PR#>
```

## Workflow

### Step 1: Setup

Parse the repo owner and name from the git remote:

```bash
REMOTE_URL=$(git remote get-url origin)
OWNER=$(echo "$REMOTE_URL" | sed -E 's#.*[:/]([^/]+)/([^/.]+)(\.git)?$#\1#')
REPO=$(echo "$REMOTE_URL" | sed -E 's#.*[:/]([^/]+)/([^/.]+)(\.git)?$#\2#')
```

Checkout the PR branch and pull latest:

```bash
gh pr checkout <PR#>
git pull --rebase origin HEAD
```

### Step 2: Collect feedback from review sources

#### Source A: `@claude` PR review threads

Fetch unresolved review threads via GraphQL:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          line
          startLine
          path
          comments(first: 10) {
            nodes {
              id
              body
              author { login }
              databaseId
            }
          }
        }
      }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F pr=<PR#>
```

Filter to threads where `isResolved == false`. If using `--reviewer subagent`, skip this step.

#### Source B: Subagent reviewer

Spawn a subagent (via the Agent tool) to independently review the PR diff:

```
Prompt for subagent:
"Review the current git diff for this PR. Identify any bugs, correctness issues,
safety concerns, or significant code quality problems. For each concern, output:
- file path
- line number(s)
- description of the issue
- suggested fix
Only flag genuine problems — do not flag style nits or minor preferences.
Return your findings as a structured list."
```

The subagent runs `git diff main...HEAD` to see the full PR diff and reviews it. If using `--reviewer claude`, skip this step.

### Step 3: Merge concerns

Combine all concerns from both sources into a single list. Each concern has:
- **source**: `claude` or `subagent`
- **file**: path to the file
- **line**: line number(s)
- **description**: what the issue is
- **thread_id**: (claude only) GraphQL thread ID for resolving

Deduplicate concerns that point to the same file/line with the same issue.

### Step 4: Address each concern

For each concern, do the following:

#### 4a: Read the relevant code

Read the file and surrounding context (at least 30 lines around the referenced line). Understand the full context of what the code is doing.

#### 4b: Evaluate the feedback

Consider:
- Is this a genuine bug, oversight, or meaningful improvement?
- Is the suggestion technically correct?
- Does it align with codebase patterns and conventions?

**Be conservative with disagreements.** Only disagree if you are confident the feedback is wrong. When in doubt, make the fix.

#### 4c: Act

**If you agree:**
1. Fix the code using Edit
2. Stage and commit:
   ```bash
   git add <file>
   git commit -m "address review: <brief description>"
   ```
3. If the concern came from `@claude`, resolve the thread:
   ```bash
   gh api graphql -f query='
   mutation($threadId: ID!) {
     resolveReviewThread(input: {threadId: $threadId}) {
       thread { isResolved }
     }
   }' -f threadId="<THREAD_ID>"
   ```

**If you disagree:**
1. If the concern came from `@claude`, reply to the comment:
   ```bash
   gh api repos/{owner}/{repo}/pulls/{pull_number}/comments/{comment_id}/replies \
     -f body="<your explanation>"
   ```
   Do NOT resolve the thread.
2. Track this as a "concern" for the summary comment.

### Step 5: Push

After all concerns are processed, push all committed fixes:

```bash
git push
```

If there were no fixes to make, skip the push.

### Step 6: Trigger re-review (dangerous mode only)

Check if running in dangerous mode by reading the project's settings:

```bash
cat claude/settings.json 2>/dev/null
```

If `skipDangerousModePermissionPrompt` is `true`, post a re-review comment on the PR:

```bash
gh pr comment <PR#> --body "@claude, I addressed your comments. Please take a look at my PR.
Concerns:
- <list any threads you disagreed with or are unsure about>
- <any subagent flags you want a second opinion on>"
```

If there are no concerns: `"Concerns: none"`

This triggers `@claude` to re-review, creating the feedback loop for the next `/loop` iteration.

## Rules

1. **Never resolve a thread you disagreed with.** Only resolve threads where you made the requested fix.
2. **One commit per fix.** Keep changes atomic so reviewers can trace each fix to its comment.
3. **Do not refactor beyond the ask.** Fix what was flagged, nothing more.
4. **Do not modify test files** unless the review comment specifically asks for it.
5. **Preserve author intent.** Stay close to the existing style and approach.
6. **Idempotency.** The GraphQL query naturally filters resolved threads. The subagent only reviews the current diff. Running this skill repeatedly via `/loop` is safe — it won't duplicate work.
7. **Stop conditions.** If all `@claude` threads are resolved AND the subagent finds no issues, there is nothing to do — exit early.
