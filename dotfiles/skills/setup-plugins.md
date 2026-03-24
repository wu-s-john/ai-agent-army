---
name: setup-plugins
description: Install canonical plugin list into ~/.claude/settings.json. Use when setting up a new machine or adding missing plugins.
user-invocable: true
---

You are setting up the canonical Claude Code plugin list. Follow these steps exactly.

## Step 1: Read current settings

Read `~/.claude/settings.json`. If it doesn't exist, start with `{}`.

## Step 2: Ensure structure

Make sure `enabledPlugins` (array) and `extraKnownMarketplaces` (array) exist in the JSON.

## Step 3: Canonical plugin list

Every entry below must be present in `enabledPlugins`:

```
frontend-design@claude-plugins-official
Notion@claude-plugins-official
linear@claude-plugins-official
superpowers@claude-plugins-official
github@claude-plugins-official
slack@claude-plugins-official
hookify@claude-plugins-official
code-simplifier@claude-plugins-official
rust-analyzer-lsp@claude-plugins-official
typescript-lsp@claude-plugins-official
deploy-on-aws@agent-plugins-for-aws
code-review@claude-plugins-official
asana@claude-plugins-official
ralph-loop@claude-plugins-official
context7@claude-plugins-official
```

## Step 4: Ensure marketplace

`extraKnownMarketplaces` must include this entry (required for `deploy-on-aws`):

```json
{
  "tag": "agent-plugins-for-aws",
  "url": "https://plugins.build.aws/registry.json"
}
```

Only add it if no entry with `"tag": "agent-plugins-for-aws"` already exists.

## Step 5: Merge and write

- Preserve all existing entries in `enabledPlugins` and `extraKnownMarketplaces`
- Add only what is missing
- Write the updated JSON back to `~/.claude/settings.json` with 2-space indentation

## Step 6: Report

Tell the user:
- Which plugins were added (if any)
- Whether the marketplace entry was added (if it was)
- "Restart Claude Code for changes to take effect."
