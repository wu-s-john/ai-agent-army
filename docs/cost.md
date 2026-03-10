# Cost Tracking & Budget Enforcement

> Per-job cost tracking, budget caps, Slack alerts, and daily reports.

## EC2 Pricing (us-west-1)

| Profile | Instance | vCPUs | RAM | On-Demand $/hr | Spot $/hr (est.) |
|---|---|---|---|---|---|
| code-small | t4g.medium | 2 | 4 GB | $0.0336 | ~$0.013 |
| code-large | t4g.xlarge | 4 | 16 GB | $0.1344 | ~$0.054 |
| research | t4g.large | 2 | 8 GB | $0.0672 | ~$0.027 |
| bench | c7g.2xlarge | 8 | 16 GB | $0.2900 | ~$0.116 |
| mac-m1 | mac2.metal | 8 | 16 GB | $0.6500 | N/A |
| mac-m2pro | mac2-m2pro.metal | 12 | 32 GB | $1.5320 | N/A |

*Spot prices fluctuate. Estimates based on typical us-west-1 rates.*

**macOS dedicated hosts**: 24-hour minimum allocation. mac2.metal = $15.60/day minimum. mac2-m2pro.metal = $36.77/day minimum.

## Claude API Pricing

| Model | Input ($/M tokens) | Output ($/M tokens) |
|---|---|---|
| Opus | $15.00 | $75.00 |
| Sonnet | $3.00 | $15.00 |
| Haiku | $0.25 | $1.25 |

### Typical task costs (API only)

| Task type | Model | Est. tokens | Est. API cost |
|---|---|---|---|
| Quick fix | Sonnet | ~50K in / ~10K out | ~$0.30 |
| Standard code | Sonnet | ~200K in / ~50K out | ~$1.35 |
| Complex feature | Opus | ~300K in / ~100K out | ~$12.00 |
| PR review | Sonnet | ~100K in / ~20K out | ~$0.60 |
| Research (1hr) | Opus | ~500K in / ~200K out | ~$22.50 |

## Other Costs

### NAT Gateway

- **Data processing**: $0.045/GB
- **Hourly**: $0.045/hr (~$32/month if always running)
- Applies to all EC2 agent outbound traffic
- Personal devices don't use NAT Gateway

### Tailscale

- Free tier: up to 100 devices, 3 users
- Sufficient for most setups

### Vercel

- Free tier or Pro ($20/month) for the app + dashboard
- Serverless function invocations (generous free tier)

### Postgres

- Vercel Postgres or Neon: free tier sufficient for low-medium usage
- RDS: ~$15/month for db.t4g.micro

## Per-Job Cost Tracking

Every cost event is recorded in the `cost_events` table:

```typescript
// Record EC2 compute cost (runs periodically while instance is active)
async function recordComputeCost(resource: Resource, session: ClaudeSession) {
  const hourlyRate = INSTANCE_PRICING[resource.instance_type];
  const hours = (Date.now() - session.started_at.getTime()) / 3600000;
  const cost = hourlyRate * hours;

  await db.cost_events.create({
    job_id: session.job_id,
    task_id: session.task_id,
    session_id: session.id,
    resource_id: resource.id,
    type: 'compute',
    amount: cost,
    description: `${resource.instance_type} for ${hours.toFixed(2)}h`,
  });
}

// Record API cost (from Claude Code usage callbacks)
async function recordApiCost(session: ClaudeSession, usage: TokenUsage) {
  const model = session.model;
  const inputCost = (usage.input_tokens / 1_000_000) * API_PRICING[model].input;
  const outputCost = (usage.output_tokens / 1_000_000) * API_PRICING[model].output;
  const totalCost = inputCost + outputCost;

  await db.cost_events.create({
    job_id: session.job_id,
    task_id: session.task_id,
    session_id: session.id,
    type: 'api',
    amount: totalCost,
    description: `${model}: ${usage.input_tokens} in / ${usage.output_tokens} out`,
  });

  // Update session token totals
  await db.claude_sessions.update(session.id, {
    token_input: session.token_input + usage.input_tokens,
    token_output: session.token_output + usage.output_tokens,
    api_cost: session.api_cost + totalCost,
  });
}
```

### Cost queries

```sql
-- Total cost for a job
SELECT SUM(amount) as total
FROM cost_events
WHERE job_id = 7;

-- Cost breakdown by type
SELECT type, SUM(amount) as total
FROM cost_events
WHERE job_id = 7
GROUP BY type;

-- Today's total spend
SELECT SUM(amount) as total
FROM cost_events
WHERE recorded_at >= CURRENT_DATE;

-- Top 10 most expensive jobs this week
SELECT j.title, SUM(ce.amount) as total_cost
FROM cost_events ce
JOIN jobs j ON j.id = ce.job_id
WHERE ce.recorded_at >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY j.id, j.title
ORDER BY total_cost DESC
LIMIT 10;
```

## Budget Enforcement

### Configuration

```sql
-- Per-job default: $20
INSERT INTO budget_config (scope, max_amount, warn_threshold)
VALUES ('job', 20.00, 0.80);

-- Daily cap: $100
INSERT INTO budget_config (scope, max_amount, warn_threshold)
VALUES ('daily', 100.00, 0.80);

-- Monthly global: $1000
INSERT INTO budget_config (scope, max_amount, warn_threshold)
VALUES ('global', 1000.00, 0.80);
```

### Enforcement flow

```
Agent running
    │
    ▼
Cost event recorded
    │
    ▼
Check budget: job, daily, global
    │
    ├── < 80% → continue
    │
    ├── ≥ 80% → Slack warning, continue
    │
    └── ≥ 100% → PAUSE agent
                    │
                    ├── Slack alert: "Agent paused, budget exceeded"
                    ├── Linear comment: "Budget exceeded, awaiting approval"
                    │
                    ▼
                 Human decision:
                    ├── Increase budget → agent resumes
                    ├── Approve one-time → agent resumes with new cap
                    └── Cancel → agent terminated
```

## Slack Alerts

### Budget warning (80%)

```typescript
await slack.chat.postMessage({
  channel: ALERTS_CHANNEL,
  text: `:warning: Agent #${agentId} at 80% of job budget ($${spent.toFixed(2)}/$${budget.toFixed(2)})`,
});
```

### Budget exceeded (100%)

```typescript
await slack.chat.postMessage({
  channel: ALERTS_CHANNEL,
  blocks: [
    {
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: `:no_entry: *Agent #${agentId} PAUSED — budget exceeded*\nSpent: $${spent.toFixed(2)} / Budget: $${budget.toFixed(2)}\nTask: ${task.title}`,
      },
    },
    {
      type: 'actions',
      elements: [
        {
          type: 'button',
          text: { type: 'plain_text', text: 'Increase Budget' },
          action_id: 'increase_budget',
          value: JSON.stringify({ agentId, currentBudget: budget }),
        },
        {
          type: 'button',
          text: { type: 'plain_text', text: 'Cancel Agent' },
          style: 'danger',
          action_id: 'cancel_agent',
          value: String(agentId),
        },
      ],
    },
  ],
});
```

## Auto-Shutdown for Idle Instances

EC2 instances with no active session are terminated after 10 minutes:

```typescript
// Runs every 5 minutes
async function shutdownIdleInstances() {
  const idle = await db.resources.findIdle('ec2', 10); // idle > 10 min

  for (const resource of idle) {
    await ec2.terminateInstances({ InstanceIds: [resource.instance_id] });
    await db.resources.update(resource.id, { status: 'terminated' });
    await recordComputeCost(resource); // final cost record
  }
}
```

## Reports

### Daily report (Slack)

Posted to `#agent-reports` at end of day:

```typescript
async function dailyReport() {
  const today = await db.cost_events.sumToday();
  const byType = await db.cost_events.sumTodayByType();
  const topJobs = await db.cost_events.topJobsToday(5);
  const agentCount = await db.jobs.countTodayCompleted();

  await slack.chat.postMessage({
    channel: REPORTS_CHANNEL,
    blocks: [
      {
        type: 'header',
        text: { type: 'plain_text', text: `Daily Report — ${new Date().toLocaleDateString()}` },
      },
      {
        type: 'section',
        fields: [
          { type: 'mrkdwn', text: `*Total Spend:* $${today.toFixed(2)}` },
          { type: 'mrkdwn', text: `*Agents Run:* ${agentCount}` },
          { type: 'mrkdwn', text: `*Compute:* $${byType.compute.toFixed(2)}` },
          { type: 'mrkdwn', text: `*API:* $${byType.api.toFixed(2)}` },
        ],
      },
      {
        type: 'section',
        text: {
          type: 'mrkdwn',
          text: '*Top Jobs:*\n' + topJobs.map(j =>
            `• ${j.title}: $${j.cost.toFixed(2)}`
          ).join('\n'),
        },
      },
    ],
  });
}
```

### Weekly report

Same format, aggregated over the week. Includes trend comparison vs previous week.

## Dashboard Cost View

The `/costs` page on the dashboard shows:

| Section | Content |
|---|---|
| Today | Total, compute vs API breakdown |
| This week | Daily bar chart, running total |
| This month | Weekly bar chart, running total |
| By agent | Table: agent, task, compute cost, API cost, total |
| By resource type | Pie chart: EC2 vs personal device API costs |
| Budget status | Progress bars for job, daily, global budgets |

See [dashboard.md](dashboard.md) for full page details.

## CloudWatch Billing Alarms

Safety net independent of the app's budget logic:

```typescript
// $100/day alarm
await cloudwatch.putMetricAlarm({
  AlarmName: 'agent-army-daily-100',
  MetricName: 'EstimatedCharges',
  Namespace: 'AWS/Billing',
  Statistic: 'Maximum',
  Period: 86400,
  EvaluationPeriods: 1,
  Threshold: 100,
  ComparisonOperator: 'GreaterThanThreshold',
  AlarmActions: [SNS_TOPIC_ARN], // → email or PagerDuty
});

// $500/month alarm
await cloudwatch.putMetricAlarm({
  AlarmName: 'agent-army-monthly-500',
  MetricName: 'EstimatedCharges',
  Namespace: 'AWS/Billing',
  Statistic: 'Maximum',
  Period: 86400,
  EvaluationPeriods: 1,
  Threshold: 500,
  ComparisonOperator: 'GreaterThanThreshold',
  AlarmActions: [SNS_TOPIC_ARN],
});
```

This catches runaway costs even if the app's budget enforcement has a bug.
