# Agent Skills & Actions

> How agents are configured, what they can do, and how skills shape their behavior.

## Skills

Skills are the core unit of agent configuration. Each skill injects a section into the agent's system prompt and enables a set of actions.

| Skill | Description | Key Actions |
|---|---|---|
| `plan` | Analyze requirements, break down work, produce implementation plan | Read code, search, write plans, create sub-tasks |
| `code` | Write code, run tests, create branches and PRs | Edit files, run commands, git operations, create PRs |
| `review` | Review PRs, suggest improvements, find issues | Read diffs, comment on PRs, request changes, approve |
| `bench` | Run benchmarks, analyze performance, compare results | Run benchmarks, produce reports, compare baselines |
| `research` | Deep research across codebases/docs, produce reports | Search broadly, read docs, spawn sub-agents, produce reports |
| `manage` | Orchestrate sub-agents, coordinate multi-agent work | Spawn agents, assign tasks, monitor progress, aggregate results |
| `deploy` | Run deployments, verify health, rollback if needed | Run deploy scripts, check health endpoints, rollback |
| `explore` | Explore unfamiliar codebases, map architecture, document findings | Read widely, map dependencies, produce architecture docs |

## Skill Details

### plan

```
You are a planning agent. Your job is to:
1. Read and understand the issue requirements
2. Explore the relevant codebase to understand context
3. Produce a detailed implementation plan
4. Break the plan into concrete steps
5. Wait for human approval before proceeding

Do NOT write code. Only produce a plan.
When done, update the issue description with your plan and comment
asking for approval.
```

**Actions**: read files, search code, create plans, update Linear issue, create sub-tasks.

### code

```
You are a coding agent. Your job is to:
1. Understand the task requirements
2. Write the code to implement the solution
3. Run tests to verify correctness
4. Create a branch, commit, and open a PR
5. Report completion with PR link

Follow the project's coding conventions. Run existing tests.
Do not skip tests. If tests fail, fix the code.
```

**Actions**: edit files, run commands (build, test, lint), git operations, create PRs, comment on issues.

### review

```
You are a code review agent. Your job is to:
1. Read the PR diff carefully
2. Check for bugs, security issues, performance problems
3. Verify tests exist and are adequate
4. Check coding conventions and style
5. Leave specific, actionable review comments
6. Approve or request changes

Be thorough but not pedantic. Focus on correctness and clarity.
```

**Actions**: read diffs, comment on PRs, request changes, approve, suggest edits.

### bench

```
You are a benchmarking agent. Your job is to:
1. Set up the benchmark environment
2. Run the specified benchmarks
3. Collect results with statistical rigor
4. Compare against baselines if available
5. Produce a results report with tables and analysis

Use appropriate warmup iterations. Report p50, p95, p99.
```

**Actions**: run benchmarks, create reports, compare results, post to Slack/Linear.

### research

```
You are a research agent. Your job is to:
1. Understand the research question
2. Explore broadly — code, docs, external sources
3. Spawn sub-agents for parallel investigation if needed
4. Synthesize findings into a clear report
5. Post periodic progress updates

You may take longer than other agents. Post updates every 15 minutes.
Checkpoint your findings regularly.
```

**Actions**: read widely, search, spawn sub-agents, produce reports, post progress.

### manage

```
You are an orchestration agent. Your job is to:
1. Break the task into parallelizable sub-tasks
2. Spawn sub-agents with appropriate skills
3. Monitor their progress
4. Handle failures (retry, reassign, escalate)
5. Aggregate results and report completion

You do not write code directly. You coordinate others.
```

**Actions**: spawn agents, assign tasks, monitor, aggregate, report.

### deploy

```
You are a deployment agent. Your job is to:
1. Run the deployment script/pipeline
2. Monitor deployment progress
3. Verify health checks pass
4. Rollback if health checks fail
5. Report deployment status

Be cautious. Verify before proceeding to each stage.
```

**Actions**: run deploy commands, check health, rollback, report status.

### explore

```
You are an exploration agent. Your job is to:
1. Map the codebase structure and architecture
2. Identify key modules, entry points, and data flows
3. Document dependencies and integration points
4. Produce an architecture overview
5. Note areas of technical debt or concern

Read broadly. Focus on understanding, not changing.
```

**Actions**: read files, search code, map dependencies, produce documentation.

## Agent Actions

Actions are grouped into categories. Each skill enables a subset:

### Communication
- Post comments on Linear issues
- Post messages to Slack channels
- Update Linear custom properties
- Request human feedback
- Report progress/completion/error to app

### Code
- Read/edit/create files
- Run shell commands (build, test, lint, format)
- Git operations (branch, commit, push)
- Create/update pull requests via GitHub CLI
- Comment on pull requests

### Infrastructure
- Spawn sub-agents (with `manage` or `research` skill)
- Request resource scaling
- Access external APIs (within allowlist)

### Observation
- Search codebase (grep, glob, AST)
- Read documentation
- Fetch URLs (with restrictions)
- Read PR diffs and review comments

### Lifecycle
- Report ready/progress/complete/error
- Request restart
- Self-terminate

## Skill Assignment

Skills are stored in the `skills` table and assigned to claude sessions via `agent_skills`:

```typescript
// When creating a new claude session:
const skills = await resolveSkills(task);
// skills = ['plan', 'code'] for a "plan then code" workflow

const systemPrompt = compileSystemPrompt(skills);
// Concatenates base prompt + skill-specific sections

const session = await db.claude_sessions.create({
  task_id: task.id,
  resource_id: resource.id,
  system_prompt: systemPrompt,
  model: task.model || 'sonnet',
});

// Record skill assignment
for (const skill of skills) {
  await db.agent_skills.create({
    session_id: session.id,
    skill_id: skill.id,
  });
}
```

### Prompt compilation

```typescript
function compileSystemPrompt(skills: Skill[]): string {
  const base = `You are Agent #${agentId} working on: ${task.title}

Task description:
${task.description}

Repository: ${repo.url}
Branch: ${branch}

Report progress to: POST ${appUrl}/api/agent/progress
Report completion to: POST ${appUrl}/api/agent/complete
Report errors to: POST ${appUrl}/api/agent/error
`;

  const skillSections = skills
    .map(s => `## Skill: ${s.name}\n${s.system_prompt}`)
    .join('\n\n');

  return `${base}\n\n${skillSections}`;
}
```

## Example Agent Configurations

### Quick Fixer

For small, well-defined bugs. Fast, cheap.

```
Skills: code
Model: sonnet
Instance: t4g.medium (or personal device)
```

### Wesker (full power)

For complex features. Named after... you know.

```
Skills: plan, code, review
Model: opus
Instance: t4g.xlarge
```

### Full Stack

For features that span frontend and backend.

```
Skills: plan, code
Model: opus
Instance: t4g.xlarge
```

### Researcher

For deep investigation. May run for hours.

```
Skills: research, explore
Model: opus
Instance: t4g.large (long-running, doesn't need much compute)
```

### Reviewer

For PR review. Read-only, no code changes.

```
Skills: review
Model: sonnet
Instance: t4g.medium (or personal device)
```

### Deployer

For running deployments with safety checks.

```
Skills: deploy
Model: sonnet
Instance: t4g.medium
```

### Bench Runner

For performance testing. Needs compute.

```
Skills: bench
Model: sonnet
Instance: c7g.2xlarge
```

## Linear Label → Skill Mapping

The `agent` label activates the system. Skill assignment happens via natural language:

| Comment | Skills assigned |
|---|---|
| `@agent plan this` | plan |
| `@agent code this` (default) | code |
| `@agent plan then code` | plan, code (sequential) |
| `@agent review PR #42` | review |
| `@agent bench this` | bench |
| `@agent research this` | research |
| `@agent explore the auth module` | explore |
| `@agent skills: plan, code, review` | plan, code, review (explicit) |

If no command is given when the label is added, the default is `code`.

The app parses intent from natural language — it's not rigid syntax. "please review this PR" works the same as "@agent review PR #42".

## Custom Skill Assignment

Override default mapping with explicit skill lists:

```
@agent skills: plan, code, review
```

This gives the agent all three skills. The agent will plan first, code, then self-review before opening the PR.

Skills can also be assigned from Slack:

```
/agent spawn LINEAR-123 --skills plan,code,review
```

Or from the dashboard spawn form.
