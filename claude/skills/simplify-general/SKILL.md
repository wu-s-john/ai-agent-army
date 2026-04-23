---
name: simplify-general
description: Use when cleaning up an existing codebase to reduce AI slop — covers dedup, type consolidation, unused code removal, circular deps, weak types, defensive try/catch, deprecated paths, and noise comments. Language-agnostic workflow; pair with simplify-rust for Rust specifics.
---

# Simplify (General)

## Overview

Simplification = removing code without changing behavior. The value is in what you **delete**, not what you add. This skill covers eight independent cleanup dimensions, run as phases — investigate in parallel (read-only), reconcile in the main agent, apply changes serially.

**Artifacts go under `<repo-root>/.tmp/simplify/`.** Create the directory at the start; ensure it's gitignored.

## When NOT to use

- Fresh greenfield code — nothing to simplify yet.
- Behavioral changes — this skill is for refactors that preserve semantics only.
- Performance optimization — use `perf-engineer` instead.

## The Eight Dimensions

| # | Dimension | Primary question |
|---|---|---|
| 1 | **Dedup / DRY** | Are two functions doing the same thing differently? |
| 2 | **Type consolidation** | Are two types with the same shape serving the same role? |
| 3 | **Unused code** | Is this actually reachable or just dead? |
| 4 | **Circular deps** | Does A depend on B depend on A? |
| 5 | **Weak types** | Can `any`/`unknown`/`Box<dyn Any>` be replaced with a concrete type? |
| 6 | **Defensive try/catch** | Is this handling real unknown input, or hiding errors? |
| 7 | **Deprecated / legacy / fallback** | Is this path still reachable, or is it dead legacy? |
| 8 | **Noise comments / stubs / LARP** | Does this comment explain WHY, or just narrate WHAT? |

## Workflow (Three Phases)

### Phase 1 — Investigate (parallel, read-only)

Dispatch 8 subagents, one per dimension. Each writes findings to `.tmp/simplify/<N>-<dim>.md`. No code changes.

**Critical**: parallel writers on a shared codebase cause merge conflicts and contradictory decisions. Investigation is parallel-safe because it only reads.

Each subagent produces:
- **Findings** — specific locations (file:line) with evidence
- **Priority** — high (confirmed problem) / medium (likely) / low (stylistic)
- **Dependencies** — "blocks" or "blocked by" other dimensions

### Phase 2 — Reconcile (main agent)

Cross-reference the 8 reports:
- Same file flagged by multiple dimensions? Prioritize file-level consolidation.
- "Unused" overlaps "dedup"? Deletion wins over merging.
- "Weak types" overlaps "deprecated"? Deprecation wins over type recovery.
- Circular deps? Resolve *before* dedup (the cycle may dissolve once one edge breaks).

Output: `.tmp/simplify/plan.md` — prioritized patch order.

### Phase 3 — Apply (serial)

Execute the plan in dependency order. After each step: typecheck + tests. No parallel writers. Commit between logical steps so rollback is cheap.

**Recommended order** (empirically validated to minimize rework):
1. Remove unused code (#3) — makes later phases see less
2. Untangle cycles (#4) — may dissolve dedup candidates
3. Consolidate types (#2) — prerequisite for strong-typing
4. Dedup functions (#1) — now that types are stable
5. Replace weak types (#5)
6. Remove gratuitous error handling (#6)
7. Delete deprecated paths (#7)
8. Clean comments / slop (#8)

## Tool Stack (language-agnostic)

| Dimension | Primary tool | Notes |
|---|---|---|
| Dedup | `jscpd` | `--min-tokens 50 --min-lines 8`, multi-language, JSON + console reporters |
| Pattern expansion | `ast-grep run --lang <L> --pattern '...'` | Structural search (TS, Rust, Go, Python, etc.). Must use `run` subcommand. |
| LSP verification | `LSP documentSymbol` / `findReferences` / `hover` | Diff-scoped semantic truth; `findReferences` needs workspace index warmup |
| Circular deps | language-specific (see simplify-rust / TS equivalents) | |
| Unused code | language-specific | |
| Cycles detection | `madge` (TS), `cargo-modules` (Rust) | |

## Dedup Pipeline (works everywhere)

```
jscpd                → literal copy-paste blocks (≥50 tokens)
  ↓
ast-grep             → "where else does this pattern appear?"
  ↓
LSP documentSymbol   → verify sibling files have matching signatures
  ↓
LSP findReferences   → confirm each call site before deletion
  ↓
apply refactor       → trait/interface, shared helper, or generic
  ↓
typecheck + test     → verify behavior preserved
```

## Artifacts Layout

```
<repo-root>/.tmp/simplify/
├── 1-dedup.md
├── 2-types.md
├── 3-unused.md
├── 4-cycles.md
├── 5-weak-types.md
├── 6-error-handling.md
├── 7-deprecated.md
├── 8-noise.md
├── plan.md                    # reconciled patch order
└── raw/
    ├── jscpd-report.json
    ├── ast-grep-<pattern>.txt
    └── <other-tool-outputs>
```

Add `.tmp/` to `.gitignore` if not already.

## Guardrails

- **Never delete on guess**: LSP `findReferences` + grep + typecheck must agree before removal.
- **One dimension per commit**: enables clean bisection if something breaks.
- **Preserve comments that answer WHY**: constraint violations, workaround rationales, spec citations. Delete comments that narrate WHAT the code obviously does.
- **Defensive try/catch stays** at system boundaries (user input, network, file I/O) and where errors have genuine handling. Remove where the catch just logs and rethrows or swallows.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Dispatching parallel write-agents | Parallel for read, serial for write |
| Treating clippy/eslint hits as dedup candidates | Lints catch *local* dup; use jscpd + similarity-* for cross-file |
| Deleting before verifying references | `LSP findReferences` first, then delete |
| Running full pedantic/strict rulesets | Noise drowns signal; curate to the dedup-relevant lints |
| "Refactoring" behavior along with structure | Pure refactor only; behavior changes belong in a separate PR |

## Related Skills

- **simplify-rust** — Rust-specific tool stack (similarity-rs, cargo-machete, clippy curated, rust-analyzer LSP)
- **superpowers:verification-before-completion** — required before claiming a simplify pass is done
