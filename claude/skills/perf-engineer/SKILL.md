---
name: perf-engineer
description: macOS Apple Silicon performance engineer for Rust binaries. Diagnoses CPU, memory, I/O bottlenecks using cargo-flamegraph, xctrace, and interactive browser-based profiling (Speedscope, Perfetto). Produces Top-K summaries with visualizations.
---

# Performance Engineer Skill (macOS Apple Silicon + Rust)

## Role & Purpose

You are a macOS Apple Silicon performance engineer specializing in Rust binaries. Your mission is to diagnose CPU, memory, I/O, and scheduling issues using both CLI tools and **interactive browser-based profiling**. You produce small Top-K summaries with rich visualizations by dynamically exploring profiling UIs.

## Core Principles

1. **Capture → Convert → Condense → Redact → Analyze**
2. **Structured data first**: Prefer JSON/CSV exports for analysis
3. **Interactive browser exploration**: Keep profiling UIs open; click, zoom, and extract data dynamically
4. **Least privilege**: Execute only allow-listed commands with time limits
5. **Top-K everywhere**: Never emit unbounded lists; respect configuration

## Tool Status on macOS Apple Silicon

| Tool | Status | Symbol Resolution | Notes |
|------|--------|-------------------|-------|
| `xcrun xctrace` | ✅ Works | ✅ Full | **Primary choice** - works with SIP enabled |
| `cargo flamegraph` | ✅ Works | ✅ If SIP disabled | Requires `csrutil enable --without dtrace` |
| `samply` | ⚠️ Runs | ❌ Broken | Symbol resolution issues - shows hex addresses |
| `vmmap/heap/footprint` | ✅ Works | n/a | Memory analysis tools |

**Recommendation**:
- Use `xctrace` by default (works with SIP enabled, best symbol resolution)
- Use `cargo flamegraph` if you've disabled SIP for dtrace (produces nice SVG flamegraphs)
- Avoid `samply` until symbol resolution is fixed on macOS

## Common Gotchas

| Issue | Cause | Solution |
|-------|-------|----------|
| ~75% "unknown" samples | Idle rayon threads in parallel code | Filter to symbolicated samples only |
| No symbols in samply | macOS symbol resolution bug | Use xctrace or cargo flamegraph instead |
| Hex addresses only | `debug = 1` or symbols stripped | Use `debug = 2`, `strip = false` in Cargo.toml |
| dtrace permission denied | SIP enabled | Either disable SIP for dtrace, or use xctrace |
| Build with wrong profile | Using `--release` instead of `--profile bench` | Always use `--profile bench` for profiling |

## Configuration

Configuration lives in `perf_agent_config.toml` at the project root:

```toml
[top_k]
default = 50
cpu_symbols = 50
cpu_callers_per_symbol = 3
mem_alloc_sites = 50
mem_types = 50
fs_ops = 50
syscalls = 50
regressions = 20
suggestions = 10

[limits]
xctrace_seconds = 10
sample_seconds = 5
fs_usage_seconds = 3
browser_timeout_ms = 30000

[browser]
headless = false  # Interactive mode - keep visible for exploration
viewport_width = 1600
viewport_height = 1000
```

### Environment Overrides

Override any config value via environment variables:
- `PERF_TOP_K_CPU_SYMBOLS=200`
- `PERF_TOP_K_MEM_ALLOC_SITES=100`
- `PERF_XCTRACE_SECONDS=15`
- `PERF_SAMPLE_SECONDS=10`
- `PERF_FS_USAGE_SECONDS=5`
- `PERF_BROWSER_TIMEOUT_MS=45000`

## Pre-Profiling Setup: Mandatory Cargo.toml Configuration

### Overview

**CRITICAL**: Before any profiling work, ensure `Cargo.toml` has proper profiling settings. Without these, macOS profilers will fail to resolve Rust symbols, showing only memory addresses instead of function names.

### Why This Matters

The symbol resolution issues on macOS (addresses like 0x60df instead of function names) are caused by:

1. **Missing or incorrect debug info level**: `debug = true` is insufficient; need `debug = 2`
2. **Symbol stripping**: Default release profiles may strip symbols
3. **Missing dSYM generation**: macOS needs `split-debuginfo = "unpacked"`

**Setting these in Cargo.toml** (not just RUSTFLAGS) ensures:
- Consistent builds across all compilation modes
- Automatic dSYM generation during build
- No manual `dsymutil` step needed
- Symbols available to all profiling tools

### Required Cargo.toml Settings

Add or update the `[profile.bench]` section in `Cargo.toml`:

```toml
[profile.bench]
inherits = "release"
debug = 2                        # Full debug info (not "true")
strip = false                    # CRITICAL: Never strip symbols
split-debuginfo = "unpacked"     # macOS: generate dSYM bundles automatically
```

### Bash Helper Functions

Use these functions to automatically verify and configure Cargo.toml:

```bash
# Check if profiling config exists and is correct
check_profiling_config() {
  local cargo_toml="Cargo.toml"

  if [ ! -f "$cargo_toml" ]; then
    echo "❌ Cargo.toml not found"
    return 1
  fi

  # Check for [profile.bench] section
  if ! grep -q "^\[profile\.bench\]" "$cargo_toml"; then
    echo "⚠️  No [profile.bench] section found"
    return 1
  fi

  # Check debug level (must be explicit "2", not "true")
  if ! grep -A5 "^\[profile\.bench\]" "$cargo_toml" | grep -q "^debug = 2"; then
    echo "⚠️  debug = 2 not set (required for full symbols)"
    return 1
  fi

  # Check strip = false
  if ! grep -A5 "^\[profile\.bench\]" "$cargo_toml" | grep -q "^strip = false"; then
    echo "⚠️  strip = false not set"
    return 1
  fi

  # Check split-debuginfo (macOS-specific)
  if ! grep -A5 "^\[profile\.bench\]" "$cargo_toml" | grep -q '^split-debuginfo = "unpacked"'; then
    echo "⚠️  split-debuginfo = \"unpacked\" not set (critical for macOS)"
    return 1
  fi

  echo "✅ Profiling config is correct"
  return 0
}

# Create timestamped backup of Cargo.toml
backup_cargo_toml() {
  local cargo_toml="Cargo.toml"
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup="${cargo_toml}.bak.${timestamp}"

  if [ -f "$cargo_toml" ]; then
    cp "$cargo_toml" "$backup"
    echo "📦 Backup created: $backup"
    return 0
  else
    echo "❌ No Cargo.toml to backup"
    return 1
  fi
}

# Ensure profiling config exists and is correct
ensure_profiling_config() {
  local cargo_toml="Cargo.toml"

  echo "🔧 Ensuring profiling configuration in Cargo.toml..."

  # Check current state
  if check_profiling_config; then
    echo "✅ Configuration already correct"
    return 0
  fi

  # Create backup before modifying
  backup_cargo_toml || return 1

  # Check if [profile.bench] section exists
  if ! grep -q "^\[profile\.bench\]" "$cargo_toml"; then
    echo "➕ Adding [profile.bench] section..."
    cat >> "$cargo_toml" << 'EOF'

[profile.bench]
inherits = "release"
debug = 2                        # Full debug info
strip = false                    # Never strip symbols
split-debuginfo = "unpacked"     # macOS: auto-generate dSYM
EOF
  else
    # Section exists, update individual settings
    echo "🔄 Updating existing [profile.bench] section..."

    # Use awk to update settings within [profile.bench] section
    awk '
      /^\[profile\.bench\]/ { in_bench=1; print; next }
      /^\[/ { in_bench=0 }
      in_bench && /^debug = / { print "debug = 2                        # Full debug info"; next }
      in_bench && /^strip = / { print "strip = false                    # Never strip symbols"; next }
      in_bench && /^split-debuginfo = / { print "split-debuginfo = \"unpacked\"     # macOS: auto-generate dSYM"; next }
      { print }
    ' "$cargo_toml" > "${cargo_toml}.tmp"

    mv "${cargo_toml}.tmp" "$cargo_toml"

    # Add missing settings if they weren't in the section
    if ! grep -A10 "^\[profile\.bench\]" "$cargo_toml" | grep -q "^debug = "; then
      # Insert after [profile.bench] line
      sed -i.tmp '/^\[profile\.bench\]/a\
debug = 2                        # Full debug info
' "$cargo_toml"
      rm -f "${cargo_toml}.tmp"
    fi

    if ! grep -A10 "^\[profile\.bench\]" "$cargo_toml" | grep -q "^strip = "; then
      sed -i.tmp '/^\[profile\.bench\]/a\
strip = false                    # Never strip symbols
' "$cargo_toml"
      rm -f "${cargo_toml}.tmp"
    fi

    if ! grep -A10 "^\[profile\.bench\]" "$cargo_toml" | grep -q "^split-debuginfo = "; then
      sed -i.tmp '/^\[profile\.bench\]/a\
split-debuginfo = "unpacked"     # macOS: auto-generate dSYM
' "$cargo_toml"
      rm -f "${cargo_toml}.tmp"
    fi
  fi

  echo "✅ Configuration updated"
  return 0
}

# Verify profiling configuration is correct
verify_profiling_config() {
  echo ""
  echo "🔍 Verifying profiling configuration..."

  if check_profiling_config; then
    echo "✅ All profiling settings are correct"
    echo ""
    echo "Current [profile.bench] section:"
    grep -A5 "^\[profile\.bench\]" Cargo.toml | head -6
    return 0
  else
    echo "❌ Profiling configuration is incomplete or incorrect"
    echo ""
    echo "Run: ensure_profiling_config"
    return 1
  fi
}

# Complete pre-flight check and setup
setup_profiling_environment() {
  echo "🚀 Setting up profiling environment..."
  echo ""

  # 1. Check Cargo.toml configuration
  if ! check_profiling_config; then
    echo "⚠️  Cargo.toml needs profiling configuration"
    echo ""
    read -p "Automatically configure Cargo.toml? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      ensure_profiling_config || return 1
    else
      echo "❌ Cannot proceed without proper configuration"
      return 1
    fi
  fi

  # 2. Verify configuration
  verify_profiling_config || return 1

  # 3. Check required tools
  echo ""
  echo "🔧 Checking required tools..."

  local missing_tools=()

  command -v xcrun >/dev/null 2>&1 || missing_tools+=("xcrun/xctrace")
  command -v dsymutil >/dev/null 2>&1 || missing_tools+=("dsymutil")
  command -v cargo >/dev/null 2>&1 || missing_tools+=("cargo")

  if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "⚠️  Missing tools: ${missing_tools[*]}"
    echo ""
    echo "Install with:"
    for tool in "${missing_tools[@]}"; do
      case "$tool" in
        xcrun/xctrace|dsymutil)
          echo "  xcode-select --install"
          ;;
        cargo)
          echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
          ;;
      esac
    done
    return 1
  fi

  echo "✅ All required tools present"
  echo ""
  echo "🎉 Profiling environment ready!"
  return 0
}
```

### Usage in Workflows

**Always run setup before profiling**:

```bash
# At the start of any profiling workflow:
setup_profiling_environment || exit 1

# Or manually:
ensure_profiling_config
verify_profiling_config

# Then proceed with profiling...
```

### Integration with Profiling Workflows

Add this check to all profiling playbooks:

```bash
# Example: CPU profiling workflow
echo "1. Setting up profiling environment..."
setup_profiling_environment || exit 1

echo "2. Building with profiling symbols..."
background_build bench mybinary || exit 1

echo "3. Running profiler..."
cargo flamegraph --profile bench --bin mybinary -o flamegraph.svg
```

### Manual Verification

After running `ensure_profiling_config`, verify the changes:

```bash
# Show the [profile.bench] section
grep -A5 "^\[profile\.bench\]" Cargo.toml

# Expected output:
# [profile.bench]
# inherits = "release"
# debug = 2                        # Full debug info
# strip = false                    # Never strip symbols
# split-debuginfo = "unpacked"     # macOS: auto-generate dSYM
```

### Reverting Changes

If you need to restore the original Cargo.toml:

```bash
# Find the backup
ls -t Cargo.toml.bak.* | head -1

# Restore it
cp Cargo.toml.bak.YYYYMMDD_HHMMSS Cargo.toml
```

---

## Cargo Profile Management

### Production Profile (zero overhead)

```toml
# [profile.release] in Cargo.toml
[profile.release]
opt-level = 3
lto = "thin"
codegen-units = 1
panic = "abort"
debug = 0           # NO profiling metadata
incremental = false
```

### Profiling Profile (release-like with symbols)

```toml
# [profile.bench] in Cargo.toml (preferred - usually has strip=false)
[profile.bench]
inherits = "release"
debug = 2           # full debug info (needed for macOS symbol resolution)
strip = false       # CRITICAL: Do not strip symbols

# Or create custom profile.profiling
[profile.profiling]
inherits = "release"
debug = 2           # full debug info
strip = false       # CRITICAL: Do not strip symbols
```

### Build Modes

| Mode | Cargo Profile | RUSTFLAGS | Use Case |
|------|---------------|-----------|----------|
| **Prod-fast** | `release` | (unset) | Shipping / max speed |
| **Profile-lite** | `bench` | `-C debuginfo=1 -C split-debuginfo=unpacked -C target-cpu=native` | Time Profiler/Allocations, minimal overhead |
| **Profile-full** | `bench` | `-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native` | Deep stacks (best for sample/xctrace/flamegraph) |

**Important**: Use `bench` profile instead of `profiling` as it typically has `strip = false` by default. Always verify `debuginfo=2` for full debug symbols on macOS.

### Build Commands

```bash
# Production (no profiling metadata)
env -u RUSTFLAGS cargo build --release --bin <bin>
BIN=./target/release/<bin>

# Profiling (full stacks with symbols for macOS profilers)
# Note: Use debuginfo=2 for full debug info, ensure no stripping
RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native" \
  cargo build --profile bench --bin <bin>
BIN=./target/release/<bin>

# After building, generate dSYM for better symbol resolution
dsymutil ./target/release/<bin> -o ./target/release/<bin>.dSYM
```

### Background Build Pattern (Context-Efficient)

To save context space during long builds, run compilation in the background and only capture errors:

```bash
# Function: Background build with error capture
background_build() {
  local profile="$1"
  local bin="$2"
  local build_log="PerfRuns/current/build.log"

  mkdir -p PerfRuns/current

  echo "🔨 Starting background build: --profile $profile --bin $bin"

  # Start build in background, capture output
  RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native" \
    cargo build --profile "$profile" --bin "$bin" > "$build_log" 2>&1 &

  local build_pid=$!
  local elapsed=0

  # Poll every 10 seconds
  while kill -0 $build_pid 2>/dev/null; do
    sleep 10
    elapsed=$((elapsed + 10))
    echo "⏳ Building... ${elapsed}s elapsed"
  done

  # Check exit status
  if wait $build_pid; then
    echo "✅ Build succeeded in ${elapsed}s"

    # Determine binary path based on profile
    if [ "$profile" = "bench" ]; then
      echo "📍 Binary: ./target/release/$bin"
    else
      echo "📍 Binary: ./target/$profile/$bin"
    fi

    return 0
  else
    echo "❌ Build failed after ${elapsed}s"
    echo "Last 50 lines of output:"
    tail -50 "$build_log"
    return 1
  fi
}

# Usage:
background_build bench game_launch_and_shuffle_flow || exit 1
```

**When to use background builds**:
- ✅ Release/bench/profiling builds (typically 60-180s)
- ✅ Full workspace rebuilds
- ✅ When build output would exceed 500+ lines
- ❌ `cargo check` (fast, need immediate feedback)
- ❌ When actively debugging compilation errors
- ❌ First-time builds where you want to see dependency progress

**Benefits**:
- Saves 1000+ lines of "Compiling crate vX.Y.Z" messages
- Allows parallel work (explaining approach, preparing next commands)
- Still captures and shows errors on failure
- Reduces token usage by ~80% for build operations

### Profile Management Actions

- **enable_profiling_config()**: Safely add/update Cargo.toml profiles (creates backup first)
- **build_prod(bin)**: Build with production profile
- **build_profile_full(bin)**: Build with profiling profile + full RUSTFLAGS
- **background_build(profile, bin)**: Build with progress reporting, error capture only
- **revert_profiling_changes()**: Restore from backup

## CLI Tools (Allow-Listed Commands)

### A. Process Discovery & Launching

#### `pgrep <name>`
- **Purpose**: Find PID by process name
- **When**: Target already running
- **Syntax**: `PID=$(pgrep -n <name>)` or `pgrep -n -f "<full_cmd>"`
- **Output**: PID only
- **Caveats**: `-n` picks newest; `-f` matches full command line

#### `ps -p <PID> -o pid,ppid,command`
- **Purpose**: Verify PID and command
- **When**: After pgrep or background launch
- **Output**: One-line summary
- **Overhead**: Negligible

#### `./target/profiling/<bin> <args>`
- **Purpose**: Launch your binary
- **Pattern** (to capture PID):
  ```bash
  $BIN $ARGS &
  PID=$!
  echo $PID > pid.txt
  ```
- **Caveats**: Always background (&) for attach-style tools

### B. xctrace / Instruments (Headless)

#### `xcrun xctrace list templates`
- **Purpose**: Discover available template names
- **When**: First run or after Xcode upgrade
- **Output**: Save to `xctrace_templates.txt`
- **Overhead**: None (instant)

#### `xcrun xctrace record --template "<TEMPLATE>" --time-limit <secs> --output <path> --launch -- <bin> <args>`
- **Purpose**: Headless CPU/memory/system profiling
- **Templates**:
  - `"Time Profiler"` → CPU sampling, hot paths
  - `"Allocations"` → Memory allocation sites, transient vs persistent bytes
  - `"System Trace"` → Thread states, wakeups, context switches
  - `"CPU Counters"` → Hardware events (cycles, retired instructions, miss rates)
- **When**: Deep questions about CPU hot paths or memory churn
- **Prerequisites**: Build with `debuginfo=1` and frame pointers
- **Output**: `.trace` bundle (large; do NOT hand to LLM)
- **Caveats**: Always use `--time-limit` from config (default 10s)
- **Overhead**: Low to moderate depending on template

#### `xcrun xctrace export --input <trace> --toc`
- **Purpose**: List tables available in trace (table of contents)
- **When**: Before exporting; determine which tables to extract
- **Output**: `*_toc.txt` (or XML/JSON depending on Xcode version)
- **Caveats**: Table names vary by Xcode version

#### `xcrun xctrace export --input <trace> --type raw --output <path>`
- **Purpose**: Dump raw data tables for reduction
- **When**: Convert to machine-readable format
- **Process**:
  - Time Profiler: extract per-symbol self/total times → Top-K JSON
  - Allocations: aggregate bytes + counts by symbol → Top-K JSON
- **Caveats**: Schemas differ by Xcode; reducers must be table-name tolerant

### C. CPU Sampling (Lightweight)

#### `sample <PID> <seconds> -file <path>`
- **Purpose**: Quick, low-overhead stack sampling to find hot code
- **When**: Fast triage; verify suspected hotspot without full trace
- **Prerequisites**: PID known; symbols present for readability
- **Output**: `sample.txt` → reduce to counts per stack/symbol
- **Overhead**: Low; may miss ultra-short events; good for steady hotspots

#### `cargo flamegraph` (Recommended for Rust)

**Installation**:
```bash
cargo install flamegraph
```

**Commands**:

##### `cargo flamegraph --profile bench --bin <bin> -o flamegraph.svg -- <args>`
- **Purpose**: Generate interactive SVG flamegraph with proper Rust symbol resolution
- **When**: CPU profiling on macOS - handles symbol resolution better than other tools
- **Output**: Interactive SVG flamegraph
- **Overhead**: Low (uses dtrace/xctrace under the hood)

**Example**:
```bash
# Build with symbols and generate flamegraph
RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native" \
  cargo flamegraph --profile bench --bin mybench -o flamegraph.svg -- <args>
```

**Parsing flamegraph.svg for automation**:
```python
import re
# Extract function names and percentages from SVG title elements
pattern = r'<title>([^<]+)\s+\((\d+(?:,\d+)*)\s+samples?,\s+([\d.]+)%\)</title>'
matches = re.findall(pattern, svg_content)
```

#### `samply` (Not Recommended on macOS)

> **Warning**: `samply` has symbol resolution issues on macOS Apple Silicon. Symbols appear as hex addresses (0x...) even with proper dSYM bundles and correct build settings. Use `xctrace` or `cargo flamegraph` instead until this is fixed.

If you still want to try samply:
```bash
cargo install samply
samply record ./target/release/mybench -- args
# Note: Symbols will likely show as hex addresses instead of function names
```

**Known issues on macOS**:
- Shows addresses like `0x60df` instead of function names
- dSYM bundles are not properly read
- Firefox Profiler opens but with unsymbolicated data

**Use instead**: `xcrun xctrace` (works with SIP) or `cargo flamegraph` (requires SIP disabled for dtrace)

### D. Memory Footprint & VM Layout

#### `sudo /usr/bin/footprint --json <output.json> <PID>`
- **Purpose**: System-level memory accounting (dirty, clean, compressed, wired, shared)
- **When**: "Why is RSS large?", "What category dominates?"
- **Output**: `mem_footprint.json` (directly analyzable)
- **Overhead**: Low
- **Extract**: Totals per category; overall footprint
- **Requires**: sudo

#### `vmmap -summary <PID>`
- **Purpose**: VM region breakdown (MALLOC, STACK, MAPPED_FILE, VM_ALLOCATE)
- **When**: "Heap vs stacks vs mmaps?"
- **Output**: `vmmap_summary.txt` (1-2 pages)
- **Overhead**: Minimal
- **Process**: Reduce to JSON summary of key regions

### E. Heap / malloc Inspection

#### `heap -summary <PID>`
- **Purpose**: Heap zones (tiny/small/large), size-class usage, fragmentation hints
- **When**: "Lots of small vs few large allocations?"
- **Output**: `heap_summary.txt` → reduce to key lines
- **Prerequisites**: None; better with stack logging for deeper tools
- **Overhead**: Low

#### `leaks <PID>`
- **Purpose**: Reachability analysis; find likely leaks (unreachable heap blocks)
- **When**: Memory keeps rising; check for leaks at snapshots
- **Prerequisites**: Best with `MallocStackLogging=1`
- **Output**: `leaks.txt` → reduce to top leak sites with counts/bytes
- **Overhead**: Moderate (suspends process briefly)

#### `stringdups <PID>`
- **Purpose**: Detect duplicate C-strings (content-based dedup)
- **When**: Suspect "text bloat" (repeated keys/messages)
- **Output**: `stringdups.txt` → keep Top-K duplicates
- **Overhead**: Low

### F. I/O and Filesystem Activity

#### `sudo fs_usage -w -f filesys -t <seconds> <PID>`
- **Purpose**: Live filesystem activity & latencies
- **When**: "Slow but low CPU" → disk/network bottlenecks suspected
- **Output**: `fs_usage.csv` (keep to 2-5s)
- **Overhead**: Moderate; keep `-t` small
- **Requires**: sudo

### G. Power / Core Utilization

#### `sudo powermetrics --samplers tasks -n 1`
- **Purpose**: One-shot per-core/cluster utilization, scheduler context
- **When**: Sanity-check cores are actually busy
- **Output**: `powermetrics.txt`
- **Overhead**: Low
- **Requires**: sudo

### H. Heap & Copy Profiling (dhat-rs)

- **When**: RSS looks reasonable but you need callsite-level allocation counts, peak heap size, or want to catch clone/memcpy hotspots that churn the allocator.

**Project wiring**
```toml
[features]
dhat-on = []  # opt-in profiling switch so prod builds stay clean

[dependencies]
dhat = { version = "0.3", features = ["heap"] }
```

**Instrumentation**
```rust
fn main() {
    #[cfg(feature = "dhat-on")]
    let _profiler = dhat::Profiler::new_heap(); // use new_copy() for memcpy/clone profiling

    run_workload();
} // profiler drops here and writes dhat-heap.json (or dhat-copy.json)
```

**Run with symbols intact**
```bash
RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native" \
  cargo run --profile bench --features dhat-on --bin <bin> -- <args>
# Outputs: target/bench/dhat-heap.json (copy mode => dhat-copy.json)
```

**Inspect locally or via browser**
```bash
cargo install dhat                               # once
dhat --json target/bench/dhat-heap.json          # opens bundled HTML viewer
# or open https://nnethercote.github.io/dump/dhat/dhat.html and load the JSON
```

Key UI panels:
- **Top sites**: callsite → live bytes, total bytes, block counts (sort by live bytes to see who holds memory, total bytes for churn)
- **Stack tree**: expand to view the full allocation call chain
- **Peak timeline**: timestamp + size of heap high-water mark
- **Copy mode**: same UI but cumulative bytes copied per callsite (clone/memcpy hotspots)

**Chrome DevTools MCP workflow**
```typescript
await mcp__chrome-devtools__new_page({ url: "file:///absolute/path/to/dhat_viewer.html" });
await mcp__chrome-devtools__wait_for({ text: "Top sites" });

const topAlloc = await mcp__chrome-devtools__evaluate_script({
  function: `() => {
    return Array.from(document.querySelectorAll('table#top-sites tbody tr'))
      .map(row => {
        const cells = row.querySelectorAll('td');
        return {
          symbol: cells[0]?.textContent?.trim(),
          liveBytes: cells[1]?.textContent?.trim(),
          totalBytes: cells[2]?.textContent?.trim(),
          blocks: cells[3]?.textContent?.trim()
        };
      })
      .filter(x => x.symbol)
      .slice(0, 50);
  }`
});

await mcp__chrome-devtools__take_screenshot({
  filePath: "PerfRuns/current/screenshots/dhat_top_sites.png"
});
```

**Interpret quickly**
- Many tiny blocks → reserve capacity, reuse buffers, or pool allocations
- Huge live bytes but few blocks → inspect owning structs; stream or borrow data
- Copy mode spikes → large-by-value clones/memcpy; refactor to references/Arc
- Peak heap timestamp → correlate with workload phase via tracing/logs

**Return format example**
```json
{
  "peak_heap": "38.6 MB at t=3.2s",
  "top_alloc_sites": [
    {"symbol": "crate::foo::parse", "live_bytes": "12.3 MB", "blocks": 1234},
    {"symbol": "crate::bar::clone", "total_bytes": "9.7 MB", "blocks": 87}
  ],
  "top_copy_sites": [
    {"symbol": "crate::Foo::clone", "copied_bytes": "4.7 MB"}
  ],
  "screenshots": ["screenshots/dhat_top_sites.png"]
}
```

Always cross-reference hot callsites with flamegraphs or Instruments results before recommending fixes.

### I. Binary Size & Monomorphization (cargo-bloat / cargo-llvm-lines)

- **When**: Binaries feel “fat,” cold starts are slow, builds take ages, or you suspect generics + big structs are being cloned/passed around too much.

**Install once**
```bash
cargo install cargo-bloat
cargo install cargo-llvm-lines
```

**cargo-bloat: understand where code size comes from**
```bash
# Crate-level view of .text usage
cargo bloat --release --crates

# Top 20 functions by contribution to binary size
cargo bloat --release -n 20

# Script-friendly output
cargo bloat --release -n 200 --message-format json > PerfRuns/current/bloat.json
```
Interpretation (newbie-friendly):
- Huge generic functions like `crate::foo::parse::<BigStruct>` near the top mean each concrete type combo generated its own copy of that logic (monomorphization).
- Structs passed by value or cloned frequently show up because the compiler inlines their memcpy/clone code into every instantiation.
- Bigger binaries → more instruction pages to load, more paging, colder instruction caches.

**cargo-llvm-lines: see which generics explode inside the compiler**
```bash
cargo llvm-lines --release > PerfRuns/current/llvm_lines.txt
```
- Counts LLVM IR lines per function; giant counts point to highly-instantiated generics that also slow builds.

**Beginner workflow**
1. Run the two commands above after a profiling build (bench/release) to collect size data.
2. Note overlapping offenders (functions that dominate both bloat and llvm-lines).
3. Refactor hot spots by passing references (`&T`), using `Arc`, or trait objects when you don’t need per-type specialization.
4. Re-run the tools to confirm shrinkage.

**Chrome DevTools MCP parsing pattern**
```typescript
const bloat = JSON.parse(await fs.readFile("PerfRuns/current/bloat.json", "utf8"));
const top = bloat.functions?.slice?.(0, 50) ?? [];

await mcp__chrome-devtools__take_screenshot({
  filePath: "PerfRuns/current/screenshots/cargo_bloat.png",
  fullPage: true
});
```

**Report template**
```json
{
  "binary_size_mb": 42.3,
  "top_bloat_functions": [
    {"symbol": "crate::foo::parse::<BigStruct>", "size_kb": 512},
    {"symbol": "crate::bar::clone::<Vec<BigStruct>>", "size_kb": 380}
  ],
  "top_llvm_lines": [
    {"symbol": "crate::foo::parse::<BigStruct>", "llvm_lines": 3421}
  ],
  "recommendations": [
    "Pass BigStruct by reference instead of value",
    "Use trait objects where monomorphization adds little"
  ]
}
```

Tie findings back to flamegraphs/dhat output: if a function is both size-heavy and CPU/heap-heavy, prioritize slimming it down.

## Crate-Focused CPU Profiling (Headless + Automated)

### Overview

Answer "what's slow in MY code?" by filtering profiling results to your crate only (e.g., `legit_poker::` functions), excluding dependency noise (ark-std, serde, etc.).

**Two Key Metrics**:
- **Self-time**: Functions where CPU is actively executing (hot loops, bottlenecks)
  - Leaf frames in call stacks
  - Example: `player_decryption::verify` at 28% means it's doing 1/3 of all work
  - **Use for**: Finding which specific functions to optimize

- **Total-time**: Functions including time in their callees (expensive operations)
  - All frames in call stacks (inclusive time)
  - Example: `shuffle_deck` at 89% means shuffling dominates runtime
  - **Use for**: Understanding which high-level operations are expensive

### Quick Start

**One-command profiling** (recommended):
```bash
./tools/profile_crate.sh --bin game_launch_and_shuffle_flow
```

Output:
```
🔥 Top Self-Time Functions (hot loops - where CPU actively executes):
  1.  28.3%  legit_poker::shuffling::player_decryption::verify
  2.  15.7%  legit_poker::elgamal::scalar_mul

⏱  Top Total-Time Functions (expensive operations - including callees):
  1.  89.2%  legit_poker::shuffling::shuffle_deck
  2.  62.3%  legit_poker::shuffling::player_decryption

✓ Full results saved to: PerfRuns/current/crate_hotspots.json
```

### Workflow Modes

#### Mode 1: Flamegraph (Recommended)
- **Best for**: Local development, most common use case
- **How it works**: Uses cargo-flamegraph with proper macOS symbol resolution
- **Command**: `cargo flamegraph --profile bench --bin <bin> -o flamegraph.svg`

#### Mode 2: Fully Headless (CI/Automation)
- **Best for**: CI/CD, remote servers, batch profiling
- **How it works**: Uses xctrace Time Profiler
- **Command**: `./tools/profile_crate.sh --bin <bin> --use-xctrace`

#### Mode 3: Interactive (Deep Investigation)
- **Best for**: Complex issues requiring manual exploration
- **How it works**: Open flamegraph.svg in browser, click to zoom

### Manual Workflows

#### xctrace Workflow (Fully Headless)
```bash
# 1. Build with symbols
RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked" \\
  cargo build --profile bench --bin <bin>
dsymutil ./target/release/<bin> -o ./target/release/<bin>.dSYM

# 2. Run xctrace
xcrun xctrace record \\
  --template "Time Profiler" \\
  --time-limit 10s \\
  --output profile.trace \\
  --launch -- ./target/release/<bin> <args>

# 3. Export time profile
xcrun xctrace export \\
  --input profile.trace \\
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \\
  --output time-profile.xml

# 4. Parse and filter to your crate
python3 tools/parse_xctrace_export.py time-profile.xml \\
  --prefix legit_poker:: \\
  --threshold 1.0 \\
  --top-k 50 \\
  --output crate_hotspots.json
```

#### Python Script for Automated xctrace Analysis

```python
#!/usr/bin/env python3
"""Parse xctrace Time Profiler XML export and extract top bottlenecks."""
import xml.etree.ElementTree as ET
from collections import defaultdict
import json
import sys

def analyze_xctrace_export(xml_path, crate_prefix=None, top_k=20):
    tree = ET.parse(xml_path)
    root = tree.getroot()

    self_time = defaultdict(int)
    total_time = defaultdict(int)
    total_samples = 0

    for row in root.iter('row'):
        backtrace = row.find('backtrace')
        if backtrace is None:
            continue

        frames = list(backtrace.iter('frame'))
        if not frames:
            continue

        # Only count if leaf frame has a name (skip unsymbolicated)
        leaf = frames[0]
        if leaf.get('name') is None:
            continue

        total_samples += 1
        self_time[leaf.get('name')] += 1

        # Total time: all named frames in stack
        seen = set()
        for frame in frames:
            fname = frame.get('name')
            if fname and fname not in seen:
                total_time[fname] += 1
                seen.add(fname)

    # Filter and sort
    def filter_and_sort(data):
        items = [(name, count) for name, count in data.items()]
        if crate_prefix:
            items = [(n, c) for n, c in items if crate_prefix in n.lower()]
        items.sort(key=lambda x: -x[1])
        return items[:top_k]

    results = {
        "total_samples": total_samples,
        "self_time": [
            {"name": n, "samples": c, "pct": round(100*c/total_samples, 2)}
            for n, c in filter_and_sort(self_time)
        ],
        "total_time": [
            {"name": n, "samples": c, "pct": round(100*c/total_samples, 2)}
            for n, c in filter_and_sort(total_time)
        ]
    }
    return results

if __name__ == "__main__":
    xml_path = sys.argv[1]
    prefix = sys.argv[2] if len(sys.argv) > 2 else None
    results = analyze_xctrace_export(xml_path, prefix)
    print(json.dumps(results, indent=2))
```

**Usage**:
```bash
# Export from xctrace
xcrun xctrace export --input profile.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output timeprofile.xml

# Analyze with Python (filter to your crate)
python3 analyze_xctrace.py timeprofile.xml spartan2

# Or analyze all functions
python3 analyze_xctrace.py timeprofile.xml
```

#### Flamegraph Workflow (Recommended)
```bash
# 1. Build with symbols and generate flamegraph in one step
RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native" \\
  cargo flamegraph --profile bench --bin <bin> -o flamegraph.svg -- <args>

# 2. Parse flamegraph SVG for your crate functions
python3 tools/parse_flamegraph.py flamegraph.svg \\
  --prefix legit_poker:: \\
  --threshold 1.0 \\
  --top-k 50 \\
  --output crate_hotspots.json
```

### Output Format

```json
{
  "metadata": {
    "crate_prefix": "legit_poker::",
    "total_samples": 10000,
    "threshold_pct": 1.0,
    "top_k": 50
  },
  "self_time": [
    {"name": "legit_poker::shuffling::player_decryption::verify", "samples": 2834, "pct": 28.3},
    {"name": "legit_poker::elgamal::scalar_mul", "samples": 1572, "pct": 15.7}
  ],
  "total_time": [
    {"name": "legit_poker::shuffling::shuffle_deck", "samples": 8921, "pct": 89.2},
    {"name": "legit_poker::shuffling::player_decryption", "samples": 6234, "pct": 62.3}
  ]
}
```

### Interpretation Guide

**Self-time analysis** (where to optimize):
- High self-time = function is actively doing work (not waiting on callees)
- Look for: hot loops, expensive computations, repeated operations
- Example: `verify` at 28% → optimize the verification algorithm

**Total-time analysis** (what's expensive):
- High total-time but low self-time = function calls many expensive sub-functions
- Look for: which high-level operations dominate, architectural bottlenecks
- Example: `shuffle_deck` at 89% total but not in self-time → most time is in callees

**Next steps**:
1. **Self-time leaders**: Profile deeper (assembly, perf counters), optimize algorithm
2. **Total-time leaders**: Drill down to see which callees dominate (use interactive browser)

### CLI Tools for Crate Profiling

#### `tools/profile_crate.sh` (Main Orchestrator)
```bash
./tools/profile_crate.sh --bin <binary> [options]
```

**Options**:
- `--bin <name>`: Binary to profile (required)
- `--use-flamegraph`: Use cargo-flamegraph (default)
- `--use-xctrace`: Use xctrace instead
- `--args "..."`: Arguments to pass to binary
- `--duration <secs>`: Override profiling duration from config
- `--prefix <crate::>`: Override crate prefix from config
- `--skip-build`: Skip building, use existing binary

**Examples**:
```bash
# Basic usage (uses flamegraph)
./tools/profile_crate.sh --bin game_launch_and_shuffle_flow

# Force xctrace (fully headless)
./tools/profile_crate.sh --bin mybench --use-xctrace --duration 15

# Pass arguments to binary
./tools/profile_crate.sh --bin mybench --args "--case shuffle --players 4"

# Different crate prefix
./tools/profile_crate.sh --bin mybench --prefix myapp::
```

#### `tools/parse_flamegraph.py`
```bash
python3 tools/parse_flamegraph.py flamegraph.svg [options]
```

**Purpose**: Extract self-time and total-time Top-K from flamegraph SVG
**When**: After `cargo flamegraph`
**Options**:
- `--prefix <crate>`: Filter to functions starting with this prefix
- `--threshold <pct>`: Only include functions ≥ this percentage (default: 1.0)
- `--top-k <N>`: Limit to top N functions per list (default: 50)
- `--output <path>`: Save JSON to path (default: stdout)

#### `tools/parse_xctrace_export.py`
```bash
python3 tools/parse_xctrace_export.py time-profile.xml [options]
```

**Purpose**: Extract self-time and total-time Top-K from xctrace XML export
**When**: After `xcrun xctrace export`
**Options**: Same as `parse_flamegraph.py`

### Configuration

Settings in `perf_agent_config.toml`:
```toml
[filtering]
crate_prefix = "legit_poker::"  # Your crate prefix
threshold_pct = 1.0              # Minimum % to include

[limits]
xctrace_seconds = 10             # Default profiling duration
```

Override via environment:
```bash
PERF_FILTERING_CRATE_PREFIX=myapp:: \\
./tools/profile_crate.sh --bin mybench
```

## Interactive Browser-Based Profiling

### Overview

Instead of one-shot "open → screenshot → close", the agent **keeps browser tabs open** and explores profiling UIs interactively using Chrome DevTools MCP. This enables:

- Drilling down based on initial findings
- Multi-view comparison (Call Tree vs Flame Graph vs Timeline)
- Dynamic filtering (by thread, time range, function)
- Precise data extraction via JavaScript evaluation
- Visual documentation of exploration path

### Chrome DevTools MCP Tools Reference

#### Navigation & Session Management
- `mcp__chrome-devtools__list_pages()` - See all open tabs
- `mcp__chrome-devtools__navigate_page(url)` - Go to profiling UI
- `mcp__chrome-devtools__select_page(pageIdx)` - Switch between tabs
- `mcp__chrome-devtools__new_page(url)` - Open new tab
- `mcp__chrome-devtools__close_page(pageIdx)` - Close tab when done

#### Interaction
- `mcp__chrome-devtools__take_snapshot()` - Get accessibility tree (best for understanding UI structure)
- `mcp__chrome-devtools__click(uid, element)` - Click buttons, tabs, flamegraph bars
- `mcp__chrome-devtools__wait_for(text)` - Wait for UI elements to appear
- `mcp__chrome-devtools__evaluate_script(function, args)` - Run custom JS to extract data

#### Data Capture
- `mcp__chrome-devtools__take_screenshot(filePath, fullPage, uid)` - Visual evidence
- `mcp__chrome-devtools__get_console_messages()` - Debug UI errors
- `mcp__chrome-devtools__list_network_requests()` - See what's loading

### Interactive Workflow Pattern

```
1. Navigate to profiling UI (Speedscope/Firefox Profiler/Perfetto/SVG)
2. Upload/load profile data
3. Take snapshot → understand UI structure
4. Click through views (Left Heavy, Call Tree, Timeline, etc.)
5. Extract Top-K data via evaluate_script (read DOM)
6. Zoom into hot functions
7. Take screenshots of key findings
8. Switch views to answer follow-up questions
9. Keep tab open for related questions
```

### Speedscope (Interactive Flamegraph Viewer)

**URL**: `https://www.speedscope.app/` or `file:///path/to/speedscope.html`

**Setup**:
```bash
# Generate static HTML (optional)
npm install -g speedscope
speedscope profile.json --out speedscope.html
```

**Interactive Workflow**:

```typescript
// 1. Navigate to Speedscope
await mcp__chrome-devtools__navigate_page({
  url: "https://www.speedscope.app/"
});

// 2. Take snapshot to see UI structure
const snapshot = await mcp__chrome-devtools__take_snapshot();
// Look for file upload input in snapshot

// 3. Upload profile
await mcp__chrome-devtools__upload_file({
  uid: "file-input-from-snapshot",
  filePath: "/path/to/profile.json"
});

// 4. Wait for rendering
await mcp__chrome-devtools__wait_for({ text: "Left Heavy" });

// 5. Click "Left Heavy" view (best for Top-K)
await mcp__chrome-devtools__click({
  uid: "left-heavy-tab-uid",
  element: "Left Heavy tab"
});

// 6. Extract Top-K functions directly from DOM
const topFunctions = await mcp__chrome-devtools__evaluate_script({
  function: `() => {
    // Speedscope renders flamegraph as SVG with title elements
    const titles = Array.from(document.querySelectorAll('g > title'));
    return titles
      .map(t => {
        const match = t.textContent.match(/^(.+?)\\s+\\((\\d+)\\s+samples?,\\s+([\\d.]+)%\\)/);
        if (!match) return null;
        return {
          name: match[1],
          samples: parseInt(match[2].replace(/,/g, '')),
          pct: parseFloat(match[3])
        };
      })
      .filter(x => x)
      .sort((a, b) => b.pct - a.pct)
      .slice(0, 50);  // Top-K from config
  }`
});

// 7. Click on hottest function to zoom
await mcp__chrome-devtools__click({
  uid: "hottest-function-bar-uid",
  element: "Hottest function bar in flamegraph"
});

// 8. Screenshot zoomed view
await mcp__chrome-devtools__take_screenshot({
  filePath: "PerfRuns/current/screenshots/speedscope_zoomed.png"
});

// 9. Switch to "Sandwich" view to see callers/callees
await mcp__chrome-devtools__click({
  uid: "sandwich-tab-uid",
  element: "Sandwich view tab"
});

// 10. Screenshot sandwich view
await mcp__chrome-devtools__take_screenshot({
  filePath: "PerfRuns/current/screenshots/speedscope_sandwich.png"
});

// 11. Extract caller/callee relationships
const callGraph = await mcp__chrome-devtools__evaluate_script({
  function: `() => {
    // Sandwich view shows callers above, callees below
    const callers = Array.from(document.querySelectorAll('.caller-row'))
      .map(r => r.textContent);
    const callees = Array.from(document.querySelectorAll('.callee-row'))
      .map(r => r.textContent);
    return { callers, callees };
  }`
});
```

**When to use Speedscope**:
- Universal format support (pprof, collapsed stacks, Chrome profiles)
- Need multiple view types (Left Heavy, Sandwich, Time Order)
- Offline/local profiling
- Shareable static HTML

### Perfetto UI (Timeline & System Trace)

**URL**: `https://ui.perfetto.dev`

**Setup**:
```bash
# Generate Perfetto trace from Rust
# Use tracing-chrome or tracing-perfetto crate
# Or convert Chrome Trace Event JSON
```

**Interactive Workflow**:

```typescript
// 1. Navigate to Perfetto
await mcp__chrome-devtools__navigate_page({
  url: "https://ui.perfetto.dev"
});

// 2. Upload trace
await mcp__chrome-devtools__upload_file({
  uid: "file-input",
  filePath: "/path/to/trace.json"
});

// 3. Wait for timeline to render
await mcp__chrome-devtools__wait_for({ text: "Overview" });

// 4. Take snapshot to understand track structure
const snapshot = await mcp__chrome-devtools__take_snapshot();

// 5. Identify time ranges with high activity
const busyRanges = await mcp__chrome-devtools__evaluate_script({
  function: `() => {
    // Perfetto exposes timeline state via globals
    const state = window.globals?.state;
    if (!state) return null;

    // Get visible time range
    const visibleWindow = state.frontendLocalState.visibleWindowTime;
    return {
      start: visibleWindow.start,
      end: visibleWindow.end,
      duration: visibleWindow.end - visibleWindow.start
    };
  }`
});

// 6. Zoom into a problematic region (100-200ms)
await mcp__chrome-devtools__evaluate_script({
  function: `() => {
    const controller = window.globals?.dispatch;
    if (!controller) return;

    // Zoom to specific time range (in nanoseconds)
    controller({
      type: 'SET_VISIBLE_WINDOW',
      start: 100000000,  // 100ms
      end: 200000000     // 200ms
    });
  }`
});

// 7. Screenshot zoomed region
await mcp__chrome-devtools__take_screenshot({
  filePath: "PerfRuns/current/screenshots/perfetto_100-200ms.png"
});

// 8. Click on a blocking slice to see details
await mcp__chrome-devtools__click({
  uid: "blocking-slice-uid",
  element: "Blocking slice in timeline"
});

// 9. Extract details panel info
const sliceDetails = await mcp__chrome-devtools__evaluate_script({
  function: `() => {
    const panel = document.querySelector('.details-panel');
    if (!panel) return null;

    return {
      name: panel.querySelector('.slice-name')?.textContent,
      duration: panel.querySelector('.duration')?.textContent,
      thread: panel.querySelector('.thread-name')?.textContent,
      stack: Array.from(panel.querySelectorAll('.stack-frame'))
        .map(f => f.textContent)
    };
  }`
});

// 10. Screenshot details panel
await mcp__chrome-devtools__take_screenshot({
  filePath: "PerfRuns/current/screenshots/perfetto_slice_details.png",
  uid: "details-panel-uid"  // screenshot specific element
});

// 11. Expand thread tracks to show nested spans
await mcp__chrome-devtools__click({
  uid: "thread-track-expand-uid",
  element: "Thread track expand button"
});

// 12. Extract summary statistics
const stats = await mcp__chrome-devtools__evaluate_script({
  function: `() => {
    // Get all visible slices and compute stats
    const slices = window.globals?.state?.engine?.slices || [];
    const totalDuration = slices.reduce((sum, s) => sum + (s.dur || 0), 0);
    const byName = {};
    slices.forEach(s => {
      if (!byName[s.name]) byName[s.name] = { count: 0, totalDur: 0 };
      byName[s.name].count++;
      byName[s.name].totalDur += (s.dur || 0);
    });

    return Object.entries(byName)
      .map(([name, data]) => ({ name, ...data }))
      .sort((a, b) => b.totalDur - a.totalDur)
      .slice(0, 50);  // Top-K
  }`
});
```

**When to use Perfetto**:
- Timeline problems ("CPU low but slow")
- Async workload analysis
- Thread state visualization (running/waiting/blocked)
- I/O and system call latency
- Multi-process correlation

### FlameGraph SVG (Static Brendan Gregg Format)

**Setup (macOS symbols intact)**:
```bash
cargo install flamegraph

# 1. Build profiling binary with symbols (bench profile never strips)
RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native" \\
  cargo build --profile bench --bin <bin>

# 2. Emit dSYM so atos/inferno can resolve Rust names
dsymutil target/bench/<bin> -o target/bench/<bin>.dSYM

# 3. Sanity check that Rust symbols exist before sampling
nm -pa target/bench/<bin> | grep -q "_ZN" && echo "✓ symbols" || echo "✗ missing symbols"

# 4. Capture flamegraph using the same bench profile (release would strip!)
RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native" \\
  cargo flamegraph --profile bench --bin <bin> -- <args>

# Produces: flamegraph.svg (addresses map to names because strip=false + dSYM)
```

**Interactive Workflow**:

```typescript
// 1. Open local SVG file
await mcp__chrome-devtools__navigate_page({
  url: "file:///absolute/path/to/flamegraph.svg"
});

// 2. Wait for SVG to load
await mcp__chrome-devtools__wait_for({ text: "samples" });

// 3. Extract Top-K WITHOUT interaction (parse <title> elements)
const topFunctions = await mcp__chrome-devtools__evaluate_script({
  function: `() => {
    // SVG flamegraph puts data in <g><title> elements
    const titles = Array.from(document.querySelectorAll('g > title'));
    return titles
      .map(t => {
        // Format: "function_name (N samples, P%)"
        const match = t.textContent.match(/^(.+?)\\s*\\((\\d+)\\s+samples?,\\s+([\\d.]+)%\\)/);
        if (!match) return null;
        return {
          name: match[1].trim(),
          samples: parseInt(match[2]),
          pct: parseFloat(match[3])
        };
      })
      .filter(x => x)
      .sort((a, b) => b.samples - a.samples)
      .slice(0, 50);
  }`
});

// 4. Or explore interactively: click on a wide bar
await mcp__chrome-devtools__click({
  uid: "wide-function-rect-uid",
  element: "Wide function rectangle in flamegraph"
});

// 5. Screenshot (SVG scales to show clicked function)
await mcp__chrome-devtools__take_screenshot({
  filePath: "PerfRuns/current/screenshots/flamegraph_zoomed.png"
});

// 6. Click "Reset zoom" if available
await mcp__chrome-devtools__click({
  uid: "reset-zoom-uid",
  element: "Reset zoom button"
});

// 7. Take full overview screenshot
await mcp__chrome-devtools__take_screenshot({
  filePath: "PerfRuns/current/screenshots/flamegraph_overview.png",
  fullPage: true
});
```

**When to use FlameGraph SVG**:
- Quick, portable visualization
- Standard format from cargo-flamegraph
- No server needed (just file://)
- Hover tooltips with sample counts

### Best Practices for Interactive Exploration

1. **Always take snapshot first**: Understand UI structure before clicking
2. **Extract data via evaluate_script**: Don't rely on screenshots for numbers
3. **Keep multiple views**: Compare Call Tree vs Flame Graph vs Timeline
4. **Document the path**: Take screenshots of each exploration step
5. **Use wait_for**: Ensure UI is ready before interacting
6. **Handle timeouts gracefully**: UIs may be slow; respect `browser_timeout_ms`
7. **Close tabs when done**: Use `close_page` to free resources
8. **Validate extractions**: Check that `evaluate_script` returns expected format

## Question Playbooks (Interactive Browser-Enhanced)

### "What's the slowest part of this code path?"

**Workflow**:
1. **FIRST**: Run `setup_profiling_environment` to ensure Cargo.toml is configured
2. Build profiling binary: `build_profile_full(bin)`
3. Run Time Profiler: `xcrun xctrace record --template "Time Profiler" ...`
4. Export to Firefox Profiler JSON or convert to Speedscope
5. **Open in browser**: Navigate to Firefox Profiler or Speedscope
6. **Click "Call Tree"**: See function hierarchy
7. **Extract Top-K**: Use `evaluate_script` to read DOM table
8. **Click on top function**: Expand to see callers
9. **Switch to "Flame Graph"**: Visual representation
10. **Take screenshots**: Call tree + flame graph
11. **Return**: "Function X is 32%, called by Y (20%) and Z (12%)" + data + screenshots

**Output**:
```json
{
  "top_function": "crate::parse::parse_line",
  "self_pct": 32.1,
  "callers": [
    {"name": "crate::process::process_file", "pct": 20.3},
    {"name": "crate::batch::batch_process", "pct": 11.8}
  ],
  "screenshots": [
    "screenshots/ffprof_calltree.png",
    "screenshots/ffprof_flamegraph.png"
  ]
}
```

### "Why is it slow if CPU isn't high?"

**Workflow**:
1. Run System Trace: `xcrun xctrace record --template "System Trace" ...`
2. Convert to Perfetto format (Chrome Trace Event JSON)
3. **Open Perfetto UI**: Navigate and upload trace
4. **Identify blocking periods**: Use `evaluate_script` to find WAIT states
5. **Zoom into first blocking region**: Set visible time range
6. **Click on blocking slice**: See what it's waiting on (futex, I/O, etc.)
7. **Screenshot timeline + details**: Visual evidence
8. Run `fs_usage` for 3s to see filesystem ops
9. **Return**: "Thread blocked on futex for 45ms at timestamp 156ms; top I/O: /var/log writes" + screenshots

**Output**:
```json
{
  "analysis": "I/O bound, not CPU bound",
  "blocking_time_ms": 45,
  "blocking_type": "futex (likely mutex contention)",
  "top_io_ops": [
    {"op": "write", "path": "/var/log/app.log", "count": 234, "total_ms": 67}
  ],
  "screenshots": [
    "screenshots/perfetto_timeline.png",
    "screenshots/perfetto_blocking_slice.png"
  ]
}
```

### "What uses the most memory?"

**Workflow**:
1. Run Allocations: `xcrun xctrace record --template "Allocations" ...`
2. Export and reduce to Top-K persistent bytes
3. Run `footprint + vmmap` to classify heap vs mmaps
4. Optional: `heap -summary`, `stringdups`
5. **Return**: Top-K allocation sites + category breakdown + recommendations

**Output**:
```json
{
  "top_alloc_sites": [
    {"symbol": "crate::parse::to_string", "bytes": 18203456, "count": 112940}
  ],
  "footprint": {
    "malloc": "145 MB",
    "mapped_file": "23 MB",
    "stack": "8 MB"
  },
  "suggestions": [
    "Pre-reserve Vec capacity in parse::to_string",
    "Consider string interning for repeated keys"
  ]
}
```

### "Show me the blocking/waiting time"

**Workflow**:
1. Run System Trace with xctrace: `xcrun xctrace record --template "System Trace" ...`
2. **Open Perfetto UI**: Upload trace
3. **Identify gaps**: Use `evaluate_script` to find regions with no activity
4. **Click on blocking regions**: See what's waiting
5. **Extract blocking stacks**: Parse details panel
6. **Screenshot timeline + blocking details**
7. **Return**: "Thread spent 230ms waiting, mostly in `std::sync::Mutex::lock`" + screenshots

### "Which thread is the problem?"

**Workflow**:
1. Run xctrace Time Profiler
2. **Generate flamegraph** or **open trace in Instruments**
3. **Extract per-thread CPU %** from trace export
4. **Click on hottest thread**: Expand call tree
5. **Compare flame graphs**: Switch between threads
6. **Screenshot thread comparison**
7. **Return**: "Thread 3 is 78% busy (in `hot_func`), others mostly idle" + data + screenshots

### "What changed since the last run?"

**Workflow**:
1. Load previous bundle's `cpu_timeprofiler.json`, `mem_footprint.json`
2. Compare with current run
3. Compute % deltas for Top-K entries
4. Identify new hot functions or increased memory
5. **Optional**: Open both profiles in separate browser tabs for visual comparison
6. **Return**: Regression report with % changes + likely causes

**Output**:
```json
{
  "regressions": [
    {"function": "crate::parse::regex_match", "old_pct": 8.2, "new_pct": 25.1, "delta": "+16.9%"}
  ],
  "memory_increase": {
    "old_mb": 145,
    "new_mb": 203,
    "delta": "+58 MB (+40%)"
  },
  "likely_cause": "Regex compilation moved into hot loop"
}
```

## Output Bundle Schema

Every profiling run creates a timestamped directory:

```
PerfRuns/YYYY-MM-DDTHH-MM-SSZ/
├── meta.json                   # Metadata: host, versions, top_k config
├── manifest.json               # Allow-list of files agent can read
├── cpu_timeprofiler.json       # Top-K CPU symbols
├── mem_allocations.json        # Top-K allocation sites
├── mem_footprint.json          # System memory accounting
├── vmmap_summary.json          # VM region breakdown
├── heap_summary.json           # Heap zones summary
├── fs_usage_topk.json          # Top filesystem operations
├── leaks_topk.json             # Top leak sites (if run)
├── stringdups_topk.json        # Top duplicate strings (if run)
├── sample.txt                  # Raw sample output
├── screenshots/
│   ├── speedscope_overview.png
│   ├── speedscope_zoomed.png
│   ├── speedscope_sandwich.png
│   ├── perfetto_overview.png
│   ├── perfetto_100-200ms.png
│   ├── perfetto_blocking_slice.png
│   └── flamegraph_svg.png
└── raw/                        # Raw traces (not for LLM)
    ├── cpu.trace
    ├── alloc.trace
    └── flamegraph.svg          # cargo-flamegraph output
```

### meta.json

```json
{
  "pab_version": 1,
  "created_at": "2025-11-14T12:34:56Z",
  "host": {
    "os": "macOS",
    "arch": "arm64",
    "cpu": "Apple M4"
  },
  "tooling": {
    "xcode": "16.1",
    "flamegraph": "0.6"
  },
  "top_k": {
    "default": 50,
    "cpu_symbols": 50,
    "cpu_callers_per_symbol": 3,
    "mem_alloc_sites": 50
  },
  "limits": {
    "xctrace_seconds": 10,
    "sample_seconds": 5,
    "fs_usage_seconds": 3,
    "browser_timeout_ms": 30000
  }
}
```

### cpu_timeprofiler.json

```json
{
  "duration_s": 10,
  "top_symbols": [
    {
      "symbol": "crate::parse::parse_line",
      "self_ns": 123456789,
      "total_ns": 234567890,
      "pct": 32.1,
      "callers": [
        ["crate::process::process_file", "crate::parse::parse_line"],
        ["crate::batch::batch_process", "crate::parse::parse_line"]
      ]
    }
  ]
}
```

### mem_allocations.json

```json
{
  "top_alloc_sites": [
    {
      "symbol": "crate::parse::to_string",
      "bytes_persist": 18203456,
      "alloc_count": 112940
    }
  ]
}
```

### Redaction

Replace absolute paths and usernames with tokens before saving:
- `$HOME` → `@HOME@`
- Project root → `@PROJECT@`

Keep token map separate; do not give to agent.

## Privacy & Safety

1. **Local/offline first**: Load `file://` artifacts; web UIs don't upload by default
2. **Allow-listed origins**: Only permit:
   - `profiler.firefox.com`
   - `ui.perfetto.dev`
   - `www.speedscope.app`
   - `docs.rs`
   - `rust-lang.org`
   - `github.com`
   - `brendangregg.com`
3. **Time-box all captures**: Use configured limits for all commands
4. **Browser timeouts**: Respect `browser_timeout_ms` for page loads and interactions
5. **No credentials**: Run browsers in fresh contexts; no persistent storage
6. **Sudo only when required**: `footprint`, `fs_usage`, `powermetrics`; short duration
7. **Small artifacts only**: Top-K JSON + screenshots; never full traces to LLM
8. **Backup before edit**: Always create `.bak` before modifying `Cargo.toml`

## Installation Checklist

One-time setup on macOS Apple Silicon:

```bash
# 1. Xcode Command Line Tools (for xctrace)
xcode-select --install

# 2. Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3. Rust tools (cargo-flamegraph for CPU profiling)
cargo install flamegraph

# 4. Node.js + Speedscope (optional, for interactive viewing)
brew install node
npm install -g speedscope

# 5. Create config
cat > perf_agent_config.toml <<'EOF'
[top_k]
default = 50
cpu_symbols = 50
cpu_callers_per_symbol = 3
mem_alloc_sites = 50

[limits]
xctrace_seconds = 10
sample_seconds = 5
fs_usage_seconds = 3
browser_timeout_ms = 30000

[browser]
headless = false
viewport_width = 1600
viewport_height = 1000
EOF

echo "✓ Performance engineering tools ready!"
```

### Per-Project Setup (Required Before First Profile)

**CRITICAL**: Before profiling any Rust project, configure Cargo.toml:

```bash
# Navigate to project root
cd /path/to/your/rust/project

# Run the setup (see "Pre-Profiling Setup" section for function definitions)
setup_profiling_environment

# Or manually verify and fix:
check_profiling_config || ensure_profiling_config
```

This ensures:
- `debug = 2` (full symbol information)
- `strip = false` (symbols not stripped)
- `split-debuginfo = "unpacked"` (automatic dSYM generation on macOS)

**Without this configuration, profilers will show memory addresses instead of function names!**

## Assembly Analysis for Hot Loops

After identifying hot functions via profiling, inspect the generated assembly to understand micro-level performance.

### Tools

| Tool | Best For | Install |
|------|----------|---------|
| `cargo asm` | Rust-specific, shows source alongside asm | `cargo install cargo-show-asm` |
| `llvm-objdump` | Raw disassembly of binary | `brew install llvm` |
| `otool` | macOS native disassembler | Built-in |

### cargo asm Usage

```bash
# Install
cargo install cargo-show-asm

# List functions matching a pattern
cargo asm --lib "function_name"

# Show asm for a function in an example
cargo asm --example sumcheck_sweep "eval_one_case"

# Show asm with interleaved Rust source
cargo asm --example sumcheck_sweep "eval_one_case" --rust

# Show asm for a specific profile
cargo asm --profile bench --example mybench "hot_function"
```

### llvm-objdump Usage

```bash
# Find symbol name (Rust symbols are mangled)
nm ./target/release/examples/mybench | grep -i "function_name"

# Disassemble specific function
/opt/homebrew/opt/llvm/bin/llvm-objdump -d \
  --disassemble-symbols="__ZN...mangled_name..." \
  ./target/release/examples/mybench

# Disassemble with demangling
/opt/homebrew/opt/llvm/bin/llvm-objdump -d --demangle \
  ./target/release/examples/mybench | grep -A 50 "function_name"
```

### ARM64 Quick Reference

**Key Registers**:
- `x0-x7`: Arguments and return values
- `x8`: Indirect result location
- `x9-x15`: Temporary registers
- `x19-x28`: Callee-saved registers
- `x29`: Frame pointer (FP)
- `x30`: Link register (LR) - return address
- `sp`: Stack pointer

**Key Instructions for Field Arithmetic**:
```asm
mul   x8, x10, x11    ; x8 = low 64 bits of x10 * x11
umulh x12, x10, x11   ; x12 = high 64 bits (unsigned multiply high)
madd  x8, x9, x10, x11; x8 = x11 + (x9 * x10) - fused multiply-add
adds  x15, x15, x12   ; add with carry flag set
cinc  x16, x13, hs    ; conditional increment if carry (hs = unsigned higher or same)
adc   x8, x9, x10     ; x8 = x9 + x10 + carry
sbc   x8, x9, x10     ; x8 = x9 - x10 - !carry (subtract with borrow)
ldp   x10, x9, [x2]   ; load pair (efficient - loads 2 registers)
stp   x10, x9, [sp]   ; store pair (efficient - stores 2 registers)
```

**What to Look For**:

Good patterns:
- `ldp`/`stp` pairs = efficient memory access (loads/stores 2 registers at once)
- `madd` = fused multiply-add (single cycle)
- Tight loops with few branches
- SIMD instructions (`ld1`, `st1`, `fmla` for vectors)

Bad patterns:
- Many `bl` (branch-link) calls in hot loops = function call overhead
- Single `str`/`ldr` where `stp`/`ldp` could work
- Excessive register spills to stack
- Branch-heavy code in inner loops

### Workflow: Profile → Assembly

```bash
# 1. Profile to find hot function
xcrun xctrace record --template "Time Profiler" --time-limit 30s \
  --output profile.trace --launch -- ./target/release/examples/mybench

# 2. Identify hot function from profile (e.g., "halo2curves::arithmetic::mac" at 24%)

# 3. View assembly for that function
cargo asm --example mybench "mac" --rust

# 4. Look for optimization opportunities:
#    - Can we reduce function calls?
#    - Are there unnecessary memory operations?
#    - Is SIMD being used where possible?
```

## Troubleshooting

### "xctrace not found"
Install Xcode Command Line Tools: `xcode-select --install`

### "No symbols in profiles" (macOS Rust binaries)

**Common Issue**: macOS profiling tools (sample, flamegraph, xctrace) often fail to resolve Rust symbols, showing memory addresses (0x...) or "???" instead of function names.

**Root Causes**:
1. Symbols were stripped (`strip = true` in Cargo.toml)
2. Debug info level too low (`debug = 1` only has line tables, not full symbols)
3. dSYM bundle not generated or not in expected location
4. Rust name mangling not handled by system profilers

**Solutions** (in order of preference):

```bash
# 1. Verify build profile doesn't strip symbols
grep -A3 "\[profile.bench\]" Cargo.toml
# Should show: strip = false or no strip line

# 2. Build with full debug info and no stripping
RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked" \
  cargo build --profile bench --bin <bin>

# 3. Generate dSYM bundle explicitly
dsymutil target/release/<bin> -o target/release/<bin>.dSYM

# 4. Verify symbols are present in binary
nm -pa target/release/<bin> | grep -q "_ZN" && echo "✓ Rust symbols found" || echo "✗ No symbols"

# 5. Check dSYM bundle exists and has content
ls -lh target/release/<bin>.dSYM/Contents/Resources/DWARF/<bin>
# Should be >1MB for non-trivial binaries

```

**Why macOS struggles with Rust**:
- System profilers (sample, xctrace) were designed for C/Obj-C/Swift
- Rust's name mangling scheme is different
- DWARF debug format parsing may not handle Rust metadata fully
- dSYM bundles may not be searched automatically

**Recommended Workflow**:
1. Always build with `--profile bench` (has `strip = false`)
2. Use `debuginfo=2` not `debuginfo=1`
3. Generate dSYM with `dsymutil` after building
4. Verify symbols with `nm -pa` before profiling
5. If symbols still don't resolve after all steps, this is a known macOS limitation with Rust binaries

### "Browser automation times out"
Increase `browser_timeout_ms` in config or via `PERF_BROWSER_TIMEOUT_MS=60000`

### "Chrome DevTools snapshot is empty"
Wait longer for UI to render; use `wait_for(text)` before taking snapshot

### "evaluate_script returns null"
UI structure may have changed; take snapshot first to find correct selectors

### "Permission denied" for footprint/fs_usage
These tools require `sudo`; ensure you can run with elevated privileges

### "Top-K lists are too small/large"
Adjust values in `perf_agent_config.toml` or use environment overrides

### "Browser shows wrong data"
Clear browser cache or open in incognito/private window:
```typescript
// Use new_page instead of navigate_page for fresh context
await mcp__chrome-devtools__new_page({ url: "..." });
```

### "KeyError when parsing Firefox Profiler JSON"

**Problem**: Python scripts fail with `KeyError: 'stringTable'` when parsing profile.json

**Root Cause**: Firefox Profiler format uses `stringArray` not `stringTable` (format evolved over time)

**Correct Structure**:
```python
# ✅ CORRECT - Firefox Profiler JSON structure
profile = json.load(f)
threads = profile['threads']
main_thread = threads[0]

# Key structure fields:
string_array = main_thread['stringArray']     # NOT 'stringTable'!
frame_table = main_thread['frameTable']
stack_table = main_thread['stackTable']
samples = main_thread['samples']

# Access function names:
func_idx = frame_table['func'][frame_idx]
func_name = string_array[func_idx]
```

**Common mistakes**:
```python
# ❌ WRONG - old format or wrong assumption
string_table = main_thread['stringTable']  # KeyError!

# ❌ WRONG - incorrect nesting
func_name = main_thread['funcTable'][func_idx]['name']
```

**Debug approach**:
```python
# Inspect actual JSON structure when in doubt
import json
with open('profile.json') as f:
    profile = json.load(f)
    main_thread = profile['threads'][0]
    print("Available keys:", main_thread.keys())
    # Output: dict_keys(['stringArray', 'frameTable', 'stackTable', ...])
```

**Reference**: See `tools/parse_firefox_profiler.py` for correct parsing implementation

## Usage Examples

### Quick CPU Profiling

```bash
# User asks: "What's the slowest function?"

# Agent workflow:
# 1. Build and generate flamegraph in one step
RUSTFLAGS="-C debuginfo=2 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native" \
  cargo flamegraph --profile bench --bin mybench -o flamegraph.svg -- --case hot

# 2. Parse flamegraph SVG for top functions
python3 << 'EOF'
import re
with open('flamegraph.svg') as f:
    content = f.read()
pattern = r'<title>([^<]+)\s+\((\d+(?:,\d+)*)\s+samples?,\s+([\d.]+)%\)</title>'
matches = re.findall(pattern, content)
functions = [(name.strip(), int(samples.replace(',', '')), float(pct))
             for name, samples, pct in matches]
functions.sort(key=lambda x: -x[1])
for name, samples, pct in functions[:20]:
    print(f"{pct:6.2f}% ({samples:6d}) {name[:80]}")
EOF

# 3. Open flamegraph.svg in browser for interactive exploration
# 4. Click on hot functions to zoom in
# 5. Return answer with data
```

### Memory Leak Detection

```bash
# User asks: "Are there leaks?"

# Agent workflow:
# 1. Launch with stack logging
env MallocStackLogging=1 ./target/profiling/mybench --case leak-test &
PID=$!

# 2. Let it run, then check for leaks
sleep 10
leaks $PID > leaks.txt

# 3. Parse leaks.txt for Top-K
# 4. Return: "Found 3 leak sites: X (45 MB), Y (12 MB), Z (3 MB)"
```

### Timeline Analysis for Blocking

```bash
# User asks: "Why is my async code slow?"

# Agent workflow:
# 1. Capture with xctrace System Trace
xcrun xctrace record --template "System Trace" --time-limit 10s \
  --output trace.trace --launch -- ./target/release/mybench

# 2. Open Perfetto UI via browser or export trace
# 3. Use evaluate_script to find blocking regions
# 4. Zoom into problematic time ranges
# 5. Click on slices to see what's waiting
# 6. Extract: "Thread blocked on async runtime for 125ms"
# 7. Screenshot timeline + blocking details
```

---

**This skill is complete and ready to use. The agent will leverage both powerful CLI tools and interactive browser-based exploration to provide deep, accurate performance insights for Rust binaries on macOS Apple Silicon.**
