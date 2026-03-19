# Performance Investigation Playbooks

Question-specific investigation guides for common performance problems. Each playbook provides a complete workflow from detection to diagnosis.

## Quick Decision Tree

**"My code is slow"** → Start with samply + Firefox Profiler (lowest overhead, good UI)
**"Builds are slow"** → `cargo build --timings` + `cargo llvm-lines`
**"Binary is huge"** → `cargo bloat` + strip analysis
**"Memory growing"** → Allocations template + heap analysis
**"Low CPU but slow"** → System Trace + fs_usage + Perfetto timeline
**"Regression vs baseline"** → Load both bundles, compute Top-K deltas

---

## 1. "What's the slowest part of this code path?"

**Goal**: Identify CPU hotspots and their callers

### Workflow

**Step 1: Build profiling binary**
```bash
RUSTFLAGS="-C debuginfo=1 -C force-frame-pointers=yes -C split-debuginfo=unpacked -C target-cpu=native" \
  cargo build --profile profiling --bin mybench
```

**Step 2: Capture profile**
```bash
samply record --save-only -o profile.json -- ./target/profiling/mybench --case hot
```

**Step 3: Interactive analysis**
```typescript
// Open Firefox Profiler
await navigate_page({ url: "https://profiler.firefox.com/from-file" });
await upload_file({ uid: "file-upload-uid", filePath: "profile.json" });
await wait_for({ text: "Call Tree" });

// Extract Top-K from Call Tree
await click({ uid: "call-tree-tab-uid", element: "Call Tree tab" });
const topFunctions = await evaluate_script({ function: extractCallTreeTopK });

// Click top function, expand to see callers
await click({ uid: "top-function-uid", element: "Top function row" });
const callers = await evaluate_script({ function: extractCallers });

// Switch to Flame Graph for visual confirmation
await click({ uid: "flame-graph-tab-uid", element: "Flame Graph tab" });
await take_screenshot({ filePath: "screenshots/flamegraph.png" });
```

**Step 4: Return structured answer**
```json
{
  "top_function": "crate::parse::parse_line",
  "self_pct": 32.1,
  "total_pct": 45.3,
  "callers": [
    { "name": "crate::process::process_file", "pct": 20.3 },
    { "name": "crate::batch::batch_process", "pct": 11.8 }
  ],
  "screenshots": [
    "screenshots/call_tree.png",
    "screenshots/flamegraph.png"
  ],
  "recommendation": "parse_line is 32% self-time. Profile called from process_file (20%) and batch_process (12%). Consider optimizing regex compilation or string allocations."
}
```

---

## 2. "Why is it slow if CPU isn't high?"

**Goal**: Identify I/O bottlenecks, thread blocking, or system contention

### Workflow

**Step 1: Capture system trace**
```bash
xcrun xctrace record --template "System Trace" --time-limit 10000 \
  --output systrace.trace --launch -- ./target/profiling/mybench --case slow
```

**Step 2: Export and convert to Perfetto**
```bash
xcrun xctrace export --input systrace.trace --type raw --output systrace_raw
# Convert to Chrome Trace Event JSON (tool-specific, may require custom script)
```

**Step 3: Parallel I/O capture**
```bash
# While running the benchmark again
./target/profiling/mybench --case slow &
PID=$!
sudo fs_usage -w -f filesys -t 3 $PID > fs_usage.txt
```

**Step 4: Perfetto timeline analysis**
```typescript
await navigate_page({ url: "https://ui.perfetto.dev" });
await upload_file({ uid: "file-input-uid", filePath: "systrace.json" });
await wait_for({ text: "Overview" });

// Identify blocking periods (gaps in execution)
const blockingPeriods = await evaluate_script({
  function: `() => findBlockingSlices()  // Custom logic to find WAIT/BLOCKED states`
});

// Zoom into first blocking region
await evaluate_script({
  function: `() => {
    window.globals?.dispatch({
      type: 'SET_VISIBLE_WINDOW',
      start: ${blockingPeriods[0].start},
      end: ${blockingPeriods[0].end}
    });
  }`
});
await take_screenshot({ filePath: "screenshots/perfetto_blocking.png" });

// Click blocking slice to see stack
await click({ uid: "blocking-slice-uid", element: "Blocking slice" });
const sliceDetails = await evaluate_script({ function: extractSliceDetails });
```

**Step 5: Analyze fs_usage output**
```bash
# Parse fs_usage.txt for Top-K operations
cat fs_usage.txt | awk '{print $9, $10}' | sort | uniq -c | sort -rn | head -20
```

**Step 6: Return diagnosis**
```json
{
  "analysis": "I/O bound, not CPU bound",
  "blocking_time_ms": 45,
  "blocking_type": "futex (likely mutex contention)",
  "top_io_ops": [
    { "op": "write", "path": "/var/log/app.log", "count": 234, "total_ms": 67 },
    { "op": "read", "path": "/etc/config.toml", "count": 156, "total_ms": 23 }
  ],
  "screenshots": [
    "screenshots/perfetto_timeline.png",
    "screenshots/perfetto_blocking_slice.png"
  ],
  "recommendation": "Thread spends 45ms blocked on futex. Top I/O: 234 writes to /var/log/app.log (67ms total). Consider: 1) Async logging, 2) Reduce log verbosity, 3) Check for lock contention around logging."
}
```

---

## 3. "What uses the most memory?"

**Goal**: Identify allocation sites and memory categories

### Workflow

**Step 1: Capture allocations profile**
```bash
xcrun xctrace record --template "Allocations" --time-limit 10000 \
  --output alloc.trace --launch -- ./target/profiling/mybench --case memory
```

**Step 2: Export and reduce**
```bash
xcrun xctrace export --input alloc.trace --toc > alloc_toc.txt
# Identify table name for allocations (varies by Xcode version)
xcrun xctrace export --input alloc.trace --type raw --output alloc_raw
# Parse to Top-K allocation sites → mem_allocations.json
```

**Step 3: System memory footprint**
```bash
./target/profiling/mybench --case memory &
PID=$!
sleep 5  # Let it allocate
sudo /usr/bin/footprint --json footprint.json $PID
```

**Step 4: VM breakdown**
```bash
vmmap -summary $PID > vmmap_summary.txt
```

**Step 5: Optional heap details**
```bash
heap -summary $PID > heap_summary.txt
stringdups $PID > stringdups.txt
```

**Step 6: Return analysis**
```json
{
  "top_alloc_sites": [
    { "symbol": "crate::parse::to_string", "bytes": 18203456, "count": 112940 },
    { "symbol": "std::vec::Vec<u8>::with_capacity", "bytes": 8456123, "count": 45321 }
  ],
  "footprint": {
    "total_mb": 176,
    "malloc": "145 MB (82%)",
    "mapped_file": "23 MB (13%)",
    "stack": "8 MB (5%)"
  },
  "vmmap_summary": {
    "MALLOC_NANO": "120 MB",
    "MALLOC_SMALL": "25 MB",
    "Stack": "8 MB"
  },
  "suggestions": [
    "Pre-reserve Vec capacity in parse::to_string (112k allocations, 18MB)",
    "Consider string interning for repeated keys (check stringdups output)",
    "82% is heap allocations - focus on reducing alloc frequency"
  ]
}
```

---

## 4. "Show me the blocking/waiting time"

**Goal**: Quantify off-CPU time and identify wait causes

### Workflow

**Step 1: Capture with samply (includes off-CPU)**
```bash
samply record --save-only -o profile_offcpu.json -- ./target/profiling/mybench --case async
```

**Step 2: Open in Firefox Profiler**
```typescript
await navigate_page({ url: "https://profiler.firefox.com/from-file" });
await upload_file({ uid: "file-upload-uid", filePath: "profile_offcpu.json" });
await wait_for({ text: "Stack Chart" });

// Switch to Stack Chart (timeline view)
await click({ uid: "stack-chart-tab-uid", element: "Stack Chart tab" });
await take_screenshot({ filePath: "screenshots/timeline.png" });

// Identify gaps (off-CPU periods)
const offCpuRanges = await evaluate_script({
  function: `() => {
    // Find time ranges with no samples (thread not running)
    const samples = window.gToolbox?.getSamples?.() || [];
    const gaps = [];
    for (let i = 1; i < samples.length; i++) {
      const gap = samples[i].time - samples[i-1].time;
      if (gap > 10) {  // >10ms gap
        gaps.push({
          start: samples[i-1].time,
          end: samples[i].time,
          duration: gap,
          stack: samples[i-1].stack
        });
      }
    }
    return gaps.sort((a, b) => b.duration - a.duration).slice(0, 10);
  }`
});

// Click on first gap to see stack
await click({ uid: "gap-region-uid", element: "Off-CPU gap in timeline" });
const blockingStack = await evaluate_script({ function: extractStackFromSelection });
```

**Step 3: Return analysis**
```json
{
  "total_time_ms": 1000,
  "on_cpu_ms": 770,
  "off_cpu_ms": 230,
  "off_cpu_pct": 23,
  "blocking_stacks": [
    {
      "duration_ms": 125,
      "stack": [
        "std::sync::Mutex::lock",
        "crate::cache::Cache::get",
        "crate::process::handle_request"
      ]
    },
    {
      "duration_ms": 75,
      "stack": [
        "tokio::runtime::park",
        "tokio::task::yield_now",
        "crate::async::process"
      ]
    }
  ],
  "screenshots": [
    "screenshots/timeline.png",
    "screenshots/blocking_stack.png"
  ],
  "recommendation": "Thread spent 230ms (23%) waiting. Largest block: 125ms in Mutex::lock called from Cache::get. Consider: 1) RwLock instead of Mutex for read-heavy cache, 2) Reduce critical section size, 3) Lock-free cache (dashmap)."
}
```

---

## 5. "Which thread is the problem?"

**Goal**: Identify hot threads in multi-threaded workloads

### Workflow

**Step 1: Capture multi-threaded profile**
```bash
samply record --save-only -o profile_mt.json -- ./target/profiling/mybench --case parallel --threads 8
```

**Step 2: Per-thread analysis**
```typescript
await navigate_page({ url: "https://profiler.firefox.com/from-file" });
await upload_file({ uid: "file-upload-uid", filePath: "profile_mt.json" });
await wait_for({ text: "Call Tree" });

// Extract per-thread CPU time
const threadStats = await evaluate_script({
  function: `() =>
    window.gToolbox?.getThreads?.().map(t => ({
      name: t.name,
      samples: t.samples.length,
      pct: (t.samples.length / totalSamples * 100).toFixed(1)
    })).sort((a, b) => b.samples - a.samples) || []`
});

// Focus on hottest thread
await click({ uid: "thread-selector-uid", element: "Thread selector" });
await click({ uid: `thread-${hottestIdx}-uid`, element: `Thread ${hottestIdx}` });

// Extract Top-K for this thread
const hottestThreadTopK = await evaluate_script({ function: extractCallTreeTopK });
await take_screenshot({ filePath: `screenshots/thread_${hottestIdx}_flamegraph.png` });

// Compare with second-hottest thread
await click({ uid: `thread-${secondIdx}-uid`, element: `Thread ${secondIdx}` });
const secondThreadTopK = await evaluate_script({ function: extractCallTreeTopK });
```

**Step 3: Return analysis**
```json
{
  "thread_breakdown": [
    { "name": "worker-3", "samples": 7821, "pct": 78.2 },
    { "name": "worker-1", "samples": 1234, "pct": 12.3 },
    { "name": "worker-2", "samples": 890, "pct": 8.9 },
    { "name": "main", "samples": 55, "pct": 0.6 }
  ],
  "hottest_thread": {
    "name": "worker-3",
    "top_functions": [
      { "name": "crate::heavy::compute_hash", "pct": 65.2 },
      { "name": "sha2::compress", "pct": 45.1 }
    ]
  },
  "load_imbalance": {
    "max_pct": 78.2,
    "min_pct": 8.9,
    "ratio": 8.8,
    "analysis": "Severe imbalance: worker-3 is 8.8x busier than worker-2"
  },
  "screenshots": [
    "screenshots/thread_3_flamegraph.png",
    "screenshots/thread_1_flamegraph.png"
  ],
  "recommendation": "worker-3 is 78% busy (compute_hash dominates), others mostly idle. Check work distribution: likely uneven task sizes or poor load balancing. Consider work-stealing scheduler or finer-grained tasks."
}
```

---

## 6. "What changed since the last run?"

**Goal**: Detect performance regressions by comparing two profiling runs

### Workflow

**Step 1: Load previous bundle**
```bash
BASELINE=PerfRuns/2025-11-14T10-00-00Z
CURRENT=PerfRuns/2025-11-14T12-00-00Z

# Read baseline data
BASELINE_CPU=$(cat $BASELINE/cpu_timeprofiler.json)
BASELINE_MEM=$(cat $BASELINE/mem_footprint.json)

# Read current data
CURRENT_CPU=$(cat $CURRENT/cpu_timeprofiler.json)
CURRENT_MEM=$(cat $CURRENT/mem_footprint.json)
```

**Step 2: Compute deltas**
```python
# tools/compare_bundles.py
import json, sys
from pathlib import Path

def compare_top_k(baseline, current, threshold=5.0):
    """Find functions with >threshold% change"""
    baseline_map = {f['symbol']: f['pct'] for f in baseline['top_symbols']}
    current_map = {f['symbol']: f['pct'] for f in current['top_symbols']}

    regressions = []
    for symbol, current_pct in current_map.items():
        baseline_pct = baseline_map.get(symbol, 0.0)
        delta_pct = current_pct - baseline_pct
        if abs(delta_pct) > threshold:
            regressions.append({
                'symbol': symbol,
                'baseline_pct': baseline_pct,
                'current_pct': current_pct,
                'delta_pct': delta_pct,
                'delta_abs': abs(delta_pct)
            })

    return sorted(regressions, key=lambda x: x['delta_abs'], reverse=True)

# Usage
baseline = json.load(open(sys.argv[1] + '/cpu_timeprofiler.json'))
current = json.load(open(sys.argv[2] + '/cpu_timeprofiler.json'))
regressions = compare_top_k(baseline, current, threshold=5.0)
print(json.dumps(regressions, indent=2))
```

**Step 3: Run comparison**
```bash
python3 tools/compare_bundles.py $BASELINE $CURRENT > regressions.json
```

**Step 4: Optional visual comparison**
```typescript
// Open both profiles in separate tabs
await new_page({ url: "https://profiler.firefox.com/from-file" });  // Tab 0
await upload_file({ uid: "...", filePath: `${BASELINE}/profile.json` });

await new_page({ url: "https://profiler.firefox.com/from-file" });  // Tab 1
await upload_file({ uid: "...", filePath: `${CURRENT}/profile.json` });

// Screenshot both for visual comparison
await select_page({ pageIdx: 0 });
await take_screenshot({ filePath: "screenshots/baseline_flamegraph.png" });

await select_page({ pageIdx: 1 });
await take_screenshot({ filePath: "screenshots/current_flamegraph.png" });
```

**Step 5: Return regression report**
```json
{
  "regressions": [
    {
      "symbol": "crate::parse::regex_match",
      "baseline_pct": 8.2,
      "current_pct": 25.1,
      "delta_pct": 16.9,
      "severity": "HIGH"
    },
    {
      "symbol": "crate::cache::Cache::insert",
      "baseline_pct": 3.1,
      "current_pct": 9.7,
      "delta_pct": 6.6,
      "severity": "MEDIUM"
    }
  ],
  "memory_regression": {
    "baseline_mb": 145,
    "current_mb": 203,
    "delta_mb": 58,
    "delta_pct": 40.0
  },
  "likely_cause": "regex_match went from 8.2% to 25.1% (+16.9%). Likely cause: regex compilation moved into hot loop. Check recent commits for regex usage changes.",
  "screenshots": [
    "screenshots/baseline_flamegraph.png",
    "screenshots/current_flamegraph.png"
  ]
}
```

---

## 7. "Why are my builds so slow?"

**Goal**: Identify compilation bottlenecks

### Workflow

**Step 1: Build timing analysis**
```bash
cargo clean
cargo build --release --timings
open target/cargo-timings/cargo-timing-*.html
```

**Analyze HTML**:
- Long sequential chains (dependencies that can't parallelize)
- Heavy crates (long bars)
- Codegen vs linking time split

**Step 2: Monomorphization analysis**
```bash
cargo llvm-lines --release | head -50 > llvm_lines_top50.txt
```

**Look for**:
- Functions with 1000+ instantiations
- Generic functions appearing in many variants
- Deeply nested generic types

**Step 3: Dependency tree**
```bash
cargo tree --duplicates  # Find duplicate dependencies
cargo tree -e features   # Feature propagation
```

**Step 4: Return diagnosis**
```json
{
  "total_build_time_s": 245,
  "bottlenecks": [
    {
      "crate": "syn",
      "duration_s": 45,
      "type": "dependency",
      "recommendation": "syn is a proc-macro dependency. Consider reducing macro usage or caching builds."
    },
    {
      "crate": "my_crate",
      "duration_s": 67,
      "type": "codegen",
      "recommendation": "Codegen takes 67s. Check cargo llvm-lines output for generic bloat."
    }
  ],
  "monomorphization_bloat": [
    {
      "function": "core::iter::traits::iterator::Iterator::collect",
      "lines": 12456,
      "instantiations": 342,
      "recommendation": "Highly polymorphic. Consider: 1) Use trait objects for non-hot paths, 2) Manual specialization, 3) Type erasure"
    }
  ],
  "dependency_issues": [
    {
      "issue": "serde appears 3 times (v1.0.150, v1.0.152, v1.0.160)",
      "recommendation": "Consolidate serde versions with [patch.crates-io] or update dependencies"
    }
  ],
  "suggestions": [
    "Enable sccache or ccache for incremental builds",
    "Consider lto = 'thin' instead of lto = true (faster linking)",
    "Use codegen-units = 16 for dev profile (faster parallel codegen)",
    "Profile with -Zself-profile on nightly for deep compiler analysis"
  ]
}
```

---

## 8. "Why is my binary so large?"

**Goal**: Identify size bloat sources

### Workflow

**Step 1: Size breakdown by crate**
```bash
cargo bloat --release --crates > bloat_by_crate.txt
```

**Step 2: Size breakdown by function**
```bash
cargo bloat --release -n 100 > bloat_by_function.txt
```

**Step 3: Check for debug symbols**
```bash
strip ./target/release/mybench
ls -lh ./target/release/mybench  # Before and after strip
```

**Step 4: Analyze dependencies**
```bash
cargo tree --edges normal --depth 1 | wc -l  # Count direct deps
```

**Step 5: Return analysis**
```json
{
  "binary_size_mb": 45.2,
  "stripped_size_mb": 12.3,
  "debug_symbols_mb": 32.9,
  "largest_crates": [
    { "crate": "regex", "size_mb": 3.2, "pct": 26.0 },
    { "crate": "my_crate", "size_mb": 2.8, "pct": 22.8 },
    { "crate": "tokio", "size_mb": 1.9, "pct": 15.4 }
  ],
  "largest_functions": [
    { "function": "regex::compile", "size_kb": 456, "pct": 3.7 },
    { "function": "my_crate::parse::parse_all", "size_kb": 234, "pct": 1.9 }
  ],
  "suggestions": [
    "Strip symbols in release: [profile.release] strip = true (saves 32.9MB)",
    "Enable LTO: lto = 'thin' (typically 10-20% size reduction)",
    "Consider opt-level = 'z' for size optimization (may impact perf)",
    "Remove unused features from regex if not all needed",
    "Check for large embedded data (assets, const arrays)"
  ]
}
```

---

## 9. "Which allocator should I use?"

**Goal**: Compare allocators for this workload

### Workflow

**Step 1: Build with each allocator**
```bash
# System allocator (default)
cargo build --profile profiling
cp target/profiling/mybench mybench_system

# jemalloc
cargo build --profile profiling --features jemalloc
cp target/profiling/mybench mybench_jemalloc

# mimalloc
cargo build --profile profiling --features mimalloc_allocator
cp target/profiling/mybench mybench_mimalloc
```

**Step 2: Benchmark each**
```bash
hyperfine \
  --warmup 3 \
  --min-runs 10 \
  --export-json allocator_bench.json \
  './mybench_system --case alloc-heavy' \
  './mybench_jemalloc --case alloc-heavy' \
  './mybench_mimalloc --case alloc-heavy'
```

**Step 3: Profile each**
```bash
for alloc in system jemalloc mimalloc; do
  ./mybench_${alloc} --case alloc-heavy &
  PID=$!
  sleep 2
  sudo /usr/bin/footprint --json footprint_${alloc}.json $PID
  kill $PID
done
```

**Step 4: Compare results**
```json
{
  "performance": [
    { "allocator": "mimalloc", "mean_ms": 1234, "stddev": 45, "rank": 1 },
    { "allocator": "jemalloc", "mean_ms": 1289, "stddev": 52, "rank": 2 },
    { "allocator": "system", "mean_ms": 1456, "stddev": 67, "rank": 3 }
  ],
  "memory_footprint": [
    { "allocator": "mimalloc", "peak_mb": 145, "rank": 1 },
    { "allocator": "system", "peak_mb": 156, "rank": 2 },
    { "allocator": "jemalloc", "peak_mb": 178, "rank": 3 }
  ],
  "recommendation": "mimalloc: fastest (1234ms) and lowest memory (145MB). Use for this workload.",
  "caveats": "Results may vary with different allocation patterns. Benchmark your actual workload."
}
```

---

## CI/CD Integration Example

### GitHub Actions Workflow

```yaml
# .github/workflows/perf-regression.yml
name: Performance Regression Check

on:
  pull_request:
    branches: [main]

jobs:
  perf-check:
    runs-on: macos-latest  # Apple Silicon runner
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Need history for baseline

      - name: Install Rust
        uses: actions-rs/toolchain@v1
        with:
          profile: minimal
          toolchain: stable

      - name: Install profiling tools
        run: |
          brew install samply hyperfine
          cargo install cargo-bloat

      - name: Build baseline (main branch)
        run: |
          git checkout origin/main
          RUSTFLAGS="-C debuginfo=1" cargo build --profile profiling --bin mybench
          mv target/profiling/mybench mybench_baseline

      - name: Build PR
        run: |
          git checkout ${{ github.head_ref }}
          RUSTFLAGS="-C debuginfo=1" cargo build --profile profiling --bin mybench

      - name: Benchmark comparison
        run: |
          hyperfine \
            --warmup 3 \
            --export-json bench_results.json \
            './mybench_baseline --case perf-test' \
            './target/profiling/mybench --case perf-test'

      - name: Profile baseline
        run: |
          samply record --save-only -o baseline.json -- ./mybench_baseline --case perf-test

      - name: Profile PR
        run: |
          samply record --save-only -o pr.json -- ./target/profiling/mybench --case perf-test

      - name: Check for regressions
        run: |
          python3 tools/compare_profiles.py \
            baseline.json pr.json \
            --threshold 10.0 \
            --fail-on-regression

      - name: Binary size check
        run: |
          BASELINE_SIZE=$(stat -f%z mybench_baseline)
          PR_SIZE=$(stat -f%z target/profiling/mybench)
          DELTA=$(( (PR_SIZE - BASELINE_SIZE) * 100 / BASELINE_SIZE ))
          echo "Size change: ${DELTA}%"
          if [ $DELTA -gt 5 ]; then
            echo "ERROR: Binary size increased by more than 5%"
            exit 1
          fi

      - name: Upload profiles
        uses: actions/upload-artifact@v3
        if: failure()
        with:
          name: perf-profiles
          path: |
            baseline.json
            pr.json
            bench_results.json
```

---

**See also**:
- `perf-engineer.md` - Main skill overview
- `perf-tools-reference.md` - CLI tool catalog
- `perf-browser-workflows.md` - Interactive UI profiling
