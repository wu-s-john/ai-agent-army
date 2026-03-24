# Performance Tools Reference (macOS Apple Silicon + Rust)

This document catalogs all available performance profiling tools, organized by category. See `perf-engineer.md` for workflows and `perf-playbooks.md` for question-specific guides.

## Configuration

All tools respect limits from `perf_agent_config.toml`. See main skill file for configuration details.

## A. Process Discovery & Launching

### `pgrep <name>`
- **Purpose**: Find PID by process name
- **When**: Target already running
- **Syntax**: `PID=$(pgrep -n <name>)` or `pgrep -n -f "<full_cmd>"`
- **Output**: PID only
- **Caveats**: `-n` picks newest; `-f` matches full command line

### `ps -p <PID> -o pid,ppid,command`
- **Purpose**: Verify PID and command
- **When**: After pgrep or background launch
- **Output**: One-line summary
- **Overhead**: Negligible

### `./target/profiling/<bin> <args>`
- **Purpose**: Launch your binary
- **Pattern** (to capture PID):
  ```bash
  $BIN $ARGS &
  PID=$!
  echo $PID > pid.txt
  ```
- **Caveats**: Always background (&) for attach-style tools

## B. Build Performance Analysis

### `cargo build --timings`
- **Purpose**: Analyze build times, parallelism, and bottlenecks
- **When**: "Why are my builds slow?"
- **Output**: `cargo-timing.html` with interactive timeline
- **Usage**:
  ```bash
  cargo clean
  cargo build --release --timings
  open target/cargo-timings/cargo-timing-*.html
  ```
- **What to look for**:
  - Long sequential chains (lack of parallelism)
  - Heavy proc-macro crates
  - Codegen units vs linking time
- **Overhead**: None (build-time only)

### `cargo llvm-lines`
- **Purpose**: Find monomorphization bloat (generic expansion costs)
- **When**: "Compilation is slow, binary is large"
- **Installation**: `cargo install cargo-llvm-lines`
- **Usage**:
  ```bash
  cargo llvm-lines --release | head -50
  ```
- **Output**: Top-K functions by LLVM IR line count
- **Process**: Identify heavily-instantiated generics, consider:
  - Type erasure (trait objects)
  - Manual specialization
  - `#[inline(never)]` for cold paths
- **Overhead**: None (compile-time analysis)

### `cargo bloat`
- **Purpose**: Binary size analysis by crate and function
- **When**: "Why is my release binary so large?"
- **Installation**: `cargo install cargo-bloat`
- **Usage**:
  ```bash
  cargo bloat --release --crates       # By crate
  cargo bloat --release -n 50          # Top-K functions
  cargo bloat --release --filter <crate>  # Drill down
  ```
- **Output**: Size breakdown with percentages
- **Actions**:
  - Remove unused dependencies
  - Enable LTO: `lto = "thin"` or `lto = true`
  - Consider `opt-level = "z"` for size
  - Strip symbols: `strip = true`
- **Overhead**: None (post-build analysis)

### `cargo asm`
- **Purpose**: Inspect generated assembly for specific functions
- **When**: "Is this function being inlined/optimized correctly?"
- **Installation**: `cargo install cargo-asm`
- **Usage**:
  ```bash
  cargo asm --release crate::module::function
  ```
- **Output**: Annotated assembly with source mapping
- **What to check**:
  - Inlining: small functions should disappear
  - SIMD: look for vector instructions (e.g., `vadd`, `vmul` on ARM)
  - Bounds checks: should be eliminated in hot loops
  - Branch prediction: check for unnecessary branches
- **Overhead**: None (disassembler)

### Compile-Time Profiling (Nightly)
- **Purpose**: Self-profile the compiler to find slow passes
- **When**: Deep investigation into rustc performance
- **Usage**:
  ```bash
  cargo +nightly rustc --release -- -Zself-profile
  # Generates chrome_profiler.json
  ```
- **View**: Load in `chrome://tracing` or Perfetto
- **Caveats**: Requires nightly, experimental

## C. xctrace / Instruments (Headless)

### `xcrun xctrace list templates`
- **Purpose**: Discover available template names
- **When**: First run or after Xcode upgrade
- **Output**: Save to `xctrace_templates.txt`
- **Overhead**: None (instant)

### `xcrun xctrace record --template "<TEMPLATE>" --time-limit <secs> --output <path> --launch -- <bin> <args>`
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

### `xcrun xctrace export --input <trace> --toc`
- **Purpose**: List tables available in trace (table of contents)
- **When**: Before exporting; determine which tables to extract
- **Output**: `*_toc.txt` (or XML/JSON depending on Xcode version)
- **Caveats**: Table names vary by Xcode version

### `xcrun xctrace export --input <trace> --type raw --output <path>`
- **Purpose**: Dump raw data tables for reduction
- **When**: Convert to machine-readable format
- **Process**:
  - Time Profiler: extract per-symbol self/total times → Top-K JSON
  - Allocations: aggregate bytes + counts by symbol → Top-K JSON
- **Caveats**: Schemas differ by Xcode; reducers must be table-name tolerant

## D. CPU Sampling (Lightweight)

### `sample <PID> <seconds> -file <path>`
- **Purpose**: Quick, low-overhead stack sampling to find hot code
- **When**: Fast triage; verify suspected hotspot without full trace
- **Prerequisites**: PID known; symbols present for readability
- **Output**: `sample.txt` → reduce to counts per stack/symbol
- **Overhead**: Low; may miss ultra-short events; good for steady hotspots

### `samply` (Rust-friendly sampling profiler)

**Installation**:
```bash
brew install samply
samply setup  # one-time: enables attach on macOS
```

**Commands**:

#### `samply record --save-only -o <profile.json> -- <bin> <args>`
- **Purpose**: Headless CPU sampling with on/off-CPU support
- **When**: Scriptable sampling for AI aggregation + optional UI
- **Output**: Firefox Profiler JSON format
- **Overhead**: Low (default 1000 Hz)
- **Rate control**: `--rate <Hz>` (e.g., 2500-10000 for short runs)

#### `samply record -p <PID> --save-only -o <profile.json>`
- **Purpose**: Attach to running process
- **When**: Profile already-running target
- **Prerequisites**: `samply setup` run once
- **Output**: Same Firefox Profiler JSON

## E. Memory Footprint & VM Layout

### `sudo /usr/bin/footprint --json <output.json> <PID>`
- **Purpose**: System-level memory accounting (dirty, clean, compressed, wired, shared)
- **When**: "Why is RSS large?", "What category dominates?"
- **Output**: `mem_footprint.json` (directly analyzable)
- **Overhead**: Low
- **Extract**: Totals per category; overall footprint
- **Requires**: sudo

### `vmmap -summary <PID>`
- **Purpose**: VM region breakdown (MALLOC, STACK, MAPPED_FILE, VM_ALLOCATE)
- **When**: "Heap vs stacks vs mmaps?"
- **Output**: `vmmap_summary.txt` (1-2 pages)
- **Overhead**: Minimal
- **Process**: Reduce to JSON summary of key regions

## F. Heap / malloc Inspection

### `heap -summary <PID>`
- **Purpose**: Heap zones (tiny/small/large), size-class usage, fragmentation hints
- **When**: "Lots of small vs few large allocations?"
- **Output**: `heap_summary.txt` → reduce to key lines
- **Prerequisites**: None; better with stack logging for deeper tools
- **Overhead**: Low

### `leaks <PID>`
- **Purpose**: Reachability analysis; find likely leaks (unreachable heap blocks)
- **When**: Memory keeps rising; check for leaks at snapshots
- **Prerequisites**: Best with `MallocStackLogging=1`
- **Output**: `leaks.txt` → reduce to top leak sites with counts/bytes
- **Overhead**: Moderate (suspends process briefly)

### `stringdups <PID>`
- **Purpose**: Detect duplicate C-strings (content-based dedup)
- **When**: Suspect "text bloat" (repeated keys/messages)
- **Output**: `stringdups.txt` → keep Top-K duplicates
- **Overhead**: Low

## G. I/O and Filesystem Activity

### `sudo fs_usage -w -f filesys -t <seconds> <PID>`
- **Purpose**: Live filesystem activity & latencies
- **When**: "Slow but low CPU" → disk/network bottlenecks suspected
- **Output**: `fs_usage.csv` (keep to 2-5s)
- **Overhead**: Moderate; keep `-t` small
- **Requires**: sudo

## H. Power / Core Utilization

### `sudo powermetrics --samplers tasks -n 1`
- **Purpose**: One-shot per-core/cluster utilization, scheduler context
- **When**: Sanity-check cores are actually busy
- **Output**: `powermetrics.txt`
- **Overhead**: Low
- **Requires**: sudo

## I. Microbenchmarking

### `criterion` (Recommended)
- **Purpose**: Statistical microbenchmarking with warmup, outlier detection
- **When**: Comparing algorithm variants, measuring small functions
- **Setup**:
  ```toml
  [dev-dependencies]
  criterion = "0.5"

  [[bench]]
  name = "my_benchmark"
  harness = false
  ```
- **Usage**:
  ```bash
  cargo bench --bench my_benchmark
  ```
- **Output**: HTML reports with statistical analysis in `target/criterion/`
- **Features**:
  - Automatic warmup and iteration count tuning
  - Outlier detection and removal
  - Comparison with baseline
  - Throughput measurement
  - CSV export for custom analysis

### `hyperfine` (CLI benchmarking)
- **Purpose**: Benchmark complete command executions
- **When**: Comparing different binaries, CLI arguments, or configurations
- **Installation**: `brew install hyperfine`
- **Usage**:
  ```bash
  hyperfine \
    --warmup 3 \
    --min-runs 10 \
    './target/release/mybench --mode fast' \
    './target/release/mybench --mode slow'
  ```
- **Output**: Statistical summary with mean, stddev, min, max
- **Features**:
  - Automatic warmup
  - Parametric sweeps: `--parameter-scan N 1 100`
  - Export to JSON/CSV/Markdown
  - Shell completion overhead subtraction

## J. Rust Allocator Analysis

### Custom Allocator Profiling
Different allocators have different performance characteristics. Profile with multiple allocators to find the best fit:

**Setup** (`Cargo.toml`):
```toml
[dependencies]
# System allocator (default on macOS)
# No dependencies needed

# jemalloc
tikv-jemallocator = { version = "0.5", optional = true }

# mimalloc
mimalloc = { version = "0.1", optional = true }

[features]
jemalloc = ["tikv-jemallocator"]
mimalloc_allocator = ["mimalloc"]

[profile.profiling]
inherits = "release"
debug = 1
strip = false
```

**Usage** (`src/main.rs` or `src/lib.rs`):
```rust
#[cfg(feature = "jemalloc")]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

#[cfg(feature = "mimalloc_allocator")]
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;
```

**Benchmark**:
```bash
# System allocator
cargo build --profile profiling
samply record -o system.json -- ./target/profiling/mybench
footprint ./target/profiling/mybench > footprint_system.txt

# jemalloc
cargo build --profile profiling --features jemalloc
samply record -o jemalloc.json -- ./target/profiling/mybench
footprint ./target/profiling/mybench > footprint_jemalloc.txt

# mimalloc
cargo build --profile profiling --features mimalloc_allocator
samply record -o mimalloc.json -- ./target/profiling/mybench
footprint ./target/profiling/mybench > footprint_mimalloc.txt
```

**Compare**:
- Peak RSS (from footprint)
- Allocation/deallocation CPU time (from samply profiles)
- Fragmentation (heap summary)

**Typical characteristics**:
- **System (macOS)**: Good general-purpose, low overhead
- **jemalloc**: Better for multi-threaded workloads, less fragmentation
- **mimalloc**: Often faster for small allocations, lower memory overhead

## K. Flamegraph Generation

### `cargo flamegraph`
- **Purpose**: One-command CPU flamegraph generation
- **Installation**: `cargo install flamegraph`
- **Usage**:
  ```bash
  cargo flamegraph --bin mybench -- --case hot
  # Produces flamegraph.svg
  ```
- **Output**: Interactive SVG with hover tooltips
- **When**: Quick visual profiling without browser tools
- **Caveats**: Requires dtrace permissions on macOS (see samply as alternative)

## L. Advanced macOS Tools

### `dtrace` (System-level tracing)
- **Purpose**: Kernel-level tracing with custom probes
- **When**: Deep system call analysis, kernel interactions
- **Example** (trace syscalls):
  ```bash
  sudo dtrace -n 'syscall:::entry /pid == $target/ { @[probefunc] = count(); }' -p <PID>
  ```
- **Output**: Aggregated counts by syscall
- **Caveats**: Requires SIP partial disable on modern macOS; steep learning curve

### `instruments` (GUI, batch mode)
- **Purpose**: Same as xctrace but with GUI for exploration
- **When**: Interactive drill-down, visual timeline
- **Usage**:
  ```bash
  instruments -t "Time Profiler" -D trace.trace -l 10000 ./target/profiling/mybench
  open trace.trace  # Opens in Instruments.app
  ```
- **Overhead**: Same as xctrace

## Installation Checklist

```bash
# 1. Xcode Command Line Tools
xcode-select --install

# 2. Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3. Profiling tools
brew install samply hyperfine

# 4. Rust tooling
cargo install flamegraph cargo-bloat cargo-llvm-lines cargo-asm

# 5. samply setup
samply setup  # one-time, enables attach

# 6. Verify installation
xcrun xctrace list templates
samply --version
hyperfine --version
cargo bloat --version

echo "✓ All tools installed!"
```

## Troubleshooting

### "xctrace not found"
Install Xcode Command Line Tools: `xcode-select --install`

### "samply attach failed"
Run `samply setup` once to self-sign the binary

### "No symbols in profiles"
Verify build used `debuginfo=1` and check dSYM bundle exists:
```bash
ls -la target/profiling/*.dSYM
```

### "cargo-asm shows optimized-out function"
Function was inlined or dead-code eliminated. Check with:
```bash
cargo asm --release --lib  # Shows all functions in library
```

### "cargo llvm-lines too slow"
Use release mode and filter by crate:
```bash
cargo llvm-lines --release | grep "^  <your_crate>"
```

### "Permission denied" for footprint/fs_usage
These tools require `sudo`; ensure you can run with elevated privileges

### "hyperfine results inconsistent"
- Increase `--warmup` count (default 3, try 10)
- Disable CPU frequency scaling if possible
- Close other applications
- Use `--min-runs` to gather more samples

### "criterion benchmarks show high variance"
- Run on a quiet system (close browsers, IDEs)
- Pin to specific CPU cores if needed
- Check for background processes (Time Machine, Spotlight, etc.)
- Use `--noplot` to skip HTML generation in CI

## Tool Selection Guide

| Question | Primary Tool | Secondary Tools |
|----------|-------------|-----------------|
| What's the slowest function? | samply + Firefox Profiler | xctrace Time Profiler |
| Why is my build slow? | cargo build --timings | cargo llvm-lines |
| Why is my binary so large? | cargo bloat | cargo asm (per-function) |
| Is this function inlined? | cargo asm | cargo llvm-lines |
| Why is RSS high? | footprint + vmmap | heap, stringdups |
| Are there memory leaks? | leaks (with MallocStackLogging) | Allocations template |
| Why is it slow with low CPU? | fs_usage + System Trace | Perfetto timeline |
| Which allocator is best? | Compare footprint across allocators | samply (allocation time) |
| Is this optimization effective? | hyperfine (before/after) | criterion (micro-level) |
| What changed since last release? | Compare PerfRuns bundles | Git bisect + hyperfine |

---

**See also**:
- `perf-engineer.md` - Main skill overview and workflows
- `perf-browser-workflows.md` - Interactive UI profiling
- `perf-playbooks.md` - Question-specific investigation guides
