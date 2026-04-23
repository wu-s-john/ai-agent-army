---
name: simplify-rust
description: Use when cleaning up a Rust codebase or workspace to reduce duplication, dead code, weak types, and defensive unwrap/expect noise. Rust-specific tooling layered on the simplify-general workflow — similarity-rs, jscpd, curated clippy, ast-grep, cargo-machete, and rust-analyzer LSP.
---

# Simplify (Rust)

## Overview

Rust-specific implementation of the eight-dimension simplify workflow. Use alongside **simplify-general** (read that first for phasing and guardrails).

**Artifacts go under `<repo-root>/.tmp/simplify/`.** Ensure `.tmp/` is gitignored.

## Prerequisites

```bash
rustup component add rust-analyzer          # required for LSP; without it, LSP calls freeze
cargo install similarity-rs                 # AST-similarity detector
cargo install cargo-machete                 # unused Cargo.toml deps
pnpm add -g jscpd                           # token-based CPD (multi-language)
brew install ast-grep                       # structural search
# optional: brew install pmd                # second-opinion CPD; skip unless jscpd misses things
```

## Tool-to-Dimension Mapping

| # | Dimension | Tool(s) | Invocation |
|---|---|---|---|
| 1 | Dedup | `similarity-rs`, `jscpd` | see Dedup Pipeline |
| 2 | Type consolidation | `rust-analyzer` LSP + ast-grep | `documentSymbol` across sibling files |
| 3 | Unused code | `cargo check -W unused`, `cargo-machete` | compiler is authoritative |
| 4 | Cycles | `cargo-modules` or manual grep of `mod`/`use` | rare at crate level |
| 5 | Weak types | ast-grep on `Box<dyn Any>`, `serde_json::Value`, excessive `String` | replace via LSP hover |
| 6 | Defensive unwrap/expect | `ast-grep --pattern '$A.unwrap()'` / `.expect($_)` | see triage rules |
| 7 | Deprecated / legacy | `#[deprecated]` grep + cross-crate fork detection via jscpd | fork pattern flags this |
| 8 | Noise comments | ast-grep + manual review | no reliable automation |

## Primary Tools

### similarity-rs (AST dedup)

```bash
cd <repo-root>
mkdir -p .tmp/simplify/raw
similarity-rs --threshold 0.85 crates src \
  > .tmp/simplify/raw/similarity-rs.txt
```

- `--threshold 0.85` filters to high-confidence pairs.
- Accepts multiple path args (pass every source root — `crates`, `src`, `wasm-*`, macros, etc.).
- Reports like `file.rs:A-B method X <-> file.rs:C-D method Y  Similarity: 94%`.
- **Cross-impl matches** (e.g., `LocalStorage::store <-> S3Storage::store`) signal a missing trait.
- **From/Into symmetry** (e.g., `from_proof <-> into_proof`) is usually fine as-is; skip unless the body truly matches.

### jscpd (cross-crate fork detection)

```bash
jscpd --min-tokens 50 --min-lines 8 \
      --reporters json,console \
      --output .tmp/simplify/raw/jscpd-report \
      --ignore "**/target/**,**/node_modules/**,**/*.lock" \
      --pattern "**/*.rs" \
      . > .tmp/simplify/raw/jscpd.txt 2>&1
```

- Catches entire-file forks that similarity-rs's canonicalization misses.
- Watch for cross-crate hits — classic "mid-refactor fork" signal (e.g., `foo_core/bar.rs` duplicated in `foo/bar.rs`).

### ast-grep (targeted hunts)

```bash
AG=/opt/homebrew/Cellar/ast-grep/0.42.1/bin/ast-grep   # or `ast-grep` if on PATH

$AG run --lang rust --pattern '$A.unwrap()'
$AG run --lang rust --pattern '$A.expect($_)'
$AG run --lang rust --pattern 'let _ = $_;'
$AG run --lang rust --pattern 'Box<dyn Any>'
$AG run --lang rust --pattern 'match $E { Err($_) => { $$$; return $_; }, _ => $$$ }'
```

- **Must use `run` subcommand** — bare `--pattern` errors with "unexpected argument".
- Metavars: `$A` single-node, `$_` wildcard, `$$$` multi-node.
- For counts: `| grep -c <term>` (no `--count` flag).

### Curated clippy (skip pedantic firehose)

Pedantic + nursery together emit thousands of warnings (4k on a 12-crate workspace). Pick the dedup-relevant lints:

```bash
cargo clippy --workspace --lib --message-format=short -- \
  -W clippy::redundant_clone \
  -W clippy::needless_collect \
  -W clippy::large_enum_variant \
  -W clippy::branches_sharing_code \
  -W clippy::if_same_then_else \
  -W clippy::redundant_pattern_matching \
  -W clippy::match_same_arms \
  > .tmp/simplify/raw/clippy-dedup.txt 2>&1
```

- Use `--lib` instead of `--all-targets` — test targets often have compile errors that abort clippy.
- `--message-format=short` gives one-line-per-warning for easy counting.

### cargo-machete (unused deps)

```bash
cargo machete > .tmp/simplify/raw/machete.txt 2>&1
```

Fast (<1s). For deeper unused-export detection, requires nightly (`cargo-udeps`) — skip unless you already have nightly installed.

### LSP (rust-analyzer)

Operations via the `LSP` tool (line/char are 1-based):

```
LSP documentSymbol  filePath=<f>  line=1 char=1     # symbol inventory
LSP hover           filePath=<f>  line=N char=C     # inferred type (for weak-type recovery)
LSP findReferences  filePath=<f>  line=N char=C     # truly unused? verify before delete
LSP goToDefinition  filePath=<f>  line=N char=C     # resolve aliases
```

**Gotchas**:
- First call on a cold workspace can take 2–5 min while rust-analyzer indexes (cargo metadata + proc-macro build). Subsequent calls are fast.
- `documentSymbol` reports the symbol's *start position* (incl. doc comments/attrs) — often a few lines above `pub fn`. For `findReferences`, target the identifier column, not the `fn` keyword.
- `workspaceSymbol` in the current LSP tool has no `query` parameter, so it can't do fuzzy search — use `documentSymbol` per file instead.

## Dedup Pipeline (Rust)

```
similarity-rs (AST, ≥85%)       → ranked candidate pairs
  ↓
jscpd (token, cross-crate)      → catches forks similarity-rs misses
  ↓
LSP documentSymbol              → verify signature identity across sibling files
  ↓
ast-grep                        → "where else does this pattern appear?"
  ↓
LSP findReferences              → confirm all call sites before changing
  ↓
apply refactor                  → trait impl, shared gadget, or generic
  ↓
cargo check + cargo test        → semantics preserved
```

## Dimension-Specific Rules

### #1 Dedup

- **Cross-impl similarity** (e.g., `LocalStorage::store <-> S3Storage::store`): extract a trait. Strongest signal.
- **Cross-crate fork** (jscpd 800+ line hit between `crate_a/x.rs` and `crate_b/x.rs`): consolidate into a shared `*_core` crate. Usually mid-refactor drift.
- **from/into symmetry pairs**: typically leave alone (semantic inverses, not dups).
- **Test fixtures duplicated across crates**: move to a `test_support` crate.

### #6 unwrap / expect triage

- **Keep**: tests, build.rs, `const` initializers, provably-infallible operations on known-shape data.
- **Replace with `?`**: in fallible functions where an upstream `Result` exists.
- **Replace with `.expect("<reason>")`**: bare `.unwrap()` on genuine invariants — the string documents WHY.
- **Redesign**: repeated unwraps on `Option` in business logic → non-optional types via a constructor.

1,000+ unwraps on a 72k-line workspace is normal for crypto/circuit code (provably correct operations). Don't mass-delete; triage by module.

### #5 Weak types

Targets:
- `Box<dyn Any>` — almost always replaceable with a concrete enum or generic.
- `serde_json::Value` outside (de)serialization boundaries — model the schema as structs.
- Pervasive `String` where `&str` or `Cow<str>` suffices.

Use LSP `hover` on each call site to get the inferred concrete type rust-analyzer sees, then replace.

## Known Gotchas on Real Workspaces

- **Build errors in test targets** abort `--all-targets` clippy runs. Use `--lib` for the lint sweep.
- **Proc-macro workspaces** make rust-analyzer indexing slow — budget for the cold start.
- **Feature flag noise** (both `dev-proofs` and `prod-proofs` enabled together emits warnings). Not slop; ignore.
- **Workspace-level profiles** in member `Cargo.toml` emit "ignored" warnings. Move to root or delete.

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
├── plan.md
└── raw/
    ├── similarity-rs.txt
    ├── jscpd.txt
    ├── jscpd-report/
    ├── clippy-dedup.txt
    ├── machete.txt
    └── ast-grep-*.txt
```

## Related Skills

- **simplify-general** — phasing, guardrails, reconciliation logic (read first)
- **rust-best-practices-review** — post-simplification quality check
- **rust-reviewer** — correctness/safety review after structural changes
- **superpowers:verification-before-completion** — required before claiming the pass is done
