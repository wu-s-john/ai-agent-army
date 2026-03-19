# Interactive Browser-Based Profiling Workflows

This document provides streamlined workflows for interactive profiling using Chrome DevTools MCP. For CLI tool reference, see `perf-tools-reference.md`.

## Overview

Instead of one-shot "open → screenshot → close", the agent **keeps browser tabs open** and explores profiling UIs interactively. This enables:

- Drilling down based on initial findings
- Multi-view comparison (Call Tree vs Flame Graph vs Timeline)
- Dynamic filtering (by thread, time range, function)
- Precise data extraction via JavaScript evaluation
- Visual documentation of exploration path

## Chrome DevTools MCP Quick Reference

### Navigation & Session Management
- `list_pages()` - See all open tabs
- `navigate_page(url)` - Go to profiling UI
- `select_page(pageIdx)` - Switch between tabs
- `new_page(url)` - Open new tab
- `close_page(pageIdx)` - Close tab when done

### Interaction
- `take_snapshot()` - Get accessibility tree (best for understanding UI structure)
- `click(uid, element)` - Click buttons, tabs, flamegraph bars
- `wait_for(text)` - Wait for UI elements to appear
- `evaluate_script(function, args)` - Run custom JS to extract data

### Data Capture
- `take_screenshot(filePath, fullPage, uid)` - Visual evidence
- `get_console_messages()` - Debug UI errors
- `list_network_requests()` - See what's loading

## Standard Workflow Pattern

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

## Tool-Specific Workflows

### Speedscope (Universal Format, Multiple Views)

**URL**: `https://www.speedscope.app/`

**Condensed Workflow**:
```typescript
// 1. Navigate and upload
await navigate_page({ url: "https://www.speedscope.app/" });
const snapshot = await take_snapshot();
// Find upload input UID from snapshot
await upload_file({ uid: "file-input-uid", filePath: "/path/to/profile.json" });
await wait_for({ text: "Left Heavy" });

// 2. Extract Top-K from Left Heavy view (best for hotspot analysis)
await click({ uid: "left-heavy-tab-uid", element: "Left Heavy tab" });
const topFunctions = await evaluate_script({
  function: `() => {
    const TOP_K = ${config.top_k.cpu_symbols};
    return Array.from(document.querySelectorAll('g > title'))
      .map(t => {
        const m = t.textContent.match(/^(.+?)\\s+\\((\\d+)\\s+samples?, ([\\d.]+)%\\)/);
        return m ? { name: m[1], samples: +m[2].replace(/,/g, ''), pct: +m[3] } : null;
      })
      .filter(x => x)
      .sort((a, b) => b.pct - a.pct)
      .slice(0, TOP_K);
  }`
});

// 3. Click hottest function to zoom
await click({ uid: "hottest-bar-uid", element: "Hottest function bar" });
await take_screenshot({ filePath: "PerfRuns/current/screenshots/speedscope_zoomed.png" });

// 4. Switch to Sandwich view for caller/callee analysis
await click({ uid: "sandwich-tab-uid", element: "Sandwich view tab" });
const callGraph = await evaluate_script({
  function: `() => ({
    callers: Array.from(document.querySelectorAll('.caller-row')).map(r => r.textContent),
    callees: Array.from(document.querySelectorAll('.callee-row')).map(r => r.textContent)
  })`
});
await take_screenshot({ filePath: "PerfRuns/current/screenshots/speedscope_sandwich.png" });
```

**When to use**:
- Universal format support (pprof, collapsed stacks, Chrome profiles, Instruments)
- Need multiple view types (Left Heavy, Sandwich, Time Order)
- Offline/local profiling
- Shareable static HTML (via `speedscope profile.json --out speedscope.html`)

---

### Firefox Profiler (samply output, on/off-CPU)

**URL**: `https://profiler.firefox.com/from-file`

**Condensed Workflow**:
```typescript
// 1. Navigate and upload samply profile
await navigate_page({ url: "https://profiler.firefox.com/from-file" });
await upload_file({ uid: "file-upload-uid", filePath: "/path/to/profile.json" });
await wait_for({ text: "Call Tree" });

// 2. Extract Top-K from Call Tree
await click({ uid: "call-tree-tab-uid", element: "Call Tree tab" });
const callTree = await evaluate_script({
  function: `() => {
    const TOP_K = ${config.top_k.cpu_symbols};
    return Array.from(document.querySelectorAll('.treeViewRow'))
      .slice(0, TOP_K)
      .map(row => ({
        func: row.querySelector('.functionalName')?.textContent?.trim(),
        self: row.querySelector('.selfTime')?.textContent?.trim(),
        total: row.querySelector('.totalTime')?.textContent?.trim()
      }));
  }`
});

// 3. Expand hottest function, screenshot
await click({ uid: "hottest-row-uid", element: "Hottest function row" });
await take_screenshot({ filePath: "PerfRuns/current/screenshots/ffprof_calltree.png" });

// 4. Switch to Flame Graph
await click({ uid: "flame-graph-tab-uid", element: "Flame Graph tab" });
await wait_for({ text: "ms" });
await take_screenshot({ filePath: "PerfRuns/current/screenshots/ffprof_flamegraph.png" });

// 5. Click hot bar to zoom
await click({ uid: "hot-bar-uid", element: "Hot function bar" });
await take_screenshot({ filePath: "PerfRuns/current/screenshots/ffprof_zoomed.png" });

// 6. Per-thread analysis (if multi-threaded)
const threadStats = await evaluate_script({
  function: `() =>
    window.gToolbox?.getThreads?.().map(t => ({
      name: t.name,
      samples: t.samples.length
    })) || []`
});

// 7. Filter to main thread
await click({ uid: "thread-selector-uid", element: "Thread selector" });
await click({ uid: "main-thread-uid", element: "Main thread option" });
await take_screenshot({ filePath: "PerfRuns/current/screenshots/ffprof_main_thread.png" });
```

**When to use**:
- samply profile output (native format)
- On-CPU + off-CPU visualization
- Multi-thread analysis
- Timeline view with sample distribution
- Call tree with automatic caller/callee tracking

---

### Perfetto UI (Timeline & Async Analysis)

**URL**: `https://ui.perfetto.dev`

**Condensed Workflow**:
```typescript
// 1. Navigate and upload trace
await navigate_page({ url: "https://ui.perfetto.dev" });
await upload_file({ uid: "file-input-uid", filePath: "/path/to/trace.json" });
await wait_for({ text: "Overview" });

// 2. Identify busy time ranges
const timeRanges = await evaluate_script({
  function: `() => {
    const state = window.globals?.state;
    if (!state) return null;
    const vis = state.frontendLocalState.visibleWindowTime;
    return { start: vis.start, end: vis.end, duration: vis.end - vis.start };
  }`
});

// 3. Zoom into problematic region (example: 100-200ms)
await evaluate_script({
  function: `() => {
    window.globals?.dispatch({
      type: 'SET_VISIBLE_WINDOW',
      start: 100000000,  // 100ms in nanoseconds
      end: 200000000
    });
  }`
});
await take_screenshot({ filePath: "PerfRuns/current/screenshots/perfetto_100-200ms.png" });

// 4. Click blocking slice to see details
await click({ uid: "blocking-slice-uid", element: "Blocking slice" });
const sliceDetails = await evaluate_script({
  function: `() => {
    const panel = document.querySelector('.details-panel');
    return panel ? {
      name: panel.querySelector('.slice-name')?.textContent,
      duration: panel.querySelector('.duration')?.textContent,
      thread: panel.querySelector('.thread-name')?.textContent,
      stack: Array.from(panel.querySelectorAll('.stack-frame')).map(f => f.textContent)
    } : null;
  }`
});
await take_screenshot({
  filePath: "PerfRuns/current/screenshots/perfetto_slice_details.png",
  uid: "details-panel-uid"
});

// 5. Extract Top-K slices by duration
const topSlices = await evaluate_script({
  function: `() => {
    const TOP_K = ${config.top_k.cpu_symbols};
    const slices = window.globals?.state?.engine?.slices || [];
    const byName = {};
    slices.forEach(s => {
      const name = s.name || 'unknown';
      if (!byName[name]) byName[name] = { count: 0, totalDur: 0 };
      byName[name].count++;
      byName[name].totalDur += (s.dur || 0);
    });
    return Object.entries(byName)
      .map(([name, data]) => ({ name, ...data }))
      .sort((a, b) => b.totalDur - a.totalDur)
      .slice(0, TOP_K);
  }`
});
```

**When to use**:
- Timeline problems ("CPU low but slow")
- Async workload analysis
- Thread state visualization (running/waiting/blocked)
- I/O and system call latency
- Multi-process correlation

---

### FlameGraph SVG (Static, Portable)

**Setup**: `cargo flamegraph -- ./target/profiling/mybench`

**Condensed Workflow**:
```typescript
// 1. Open local SVG
await navigate_page({ url: "file:///absolute/path/to/flamegraph.svg" });
await wait_for({ text: "samples" });

// 2. Extract Top-K WITHOUT interaction (parse <title> elements)
const topFunctions = await evaluate_script({
  function: `() => {
    const TOP_K = ${config.top_k.cpu_symbols};
    return Array.from(document.querySelectorAll('g > title'))
      .map(t => {
        const m = t.textContent.match(/^(.+?)\\s*\\((\\d+)\\s+samples?, ([\\d.]+)%\\)/);
        return m ? { name: m[1].trim(), samples: +m[2], pct: +m[3] } : null;
      })
      .filter(x => x)
      .sort((a, b) => b.samples - a.samples)
      .slice(0, TOP_K);
  }`
});

// 3. Click wide bar to zoom (interactive exploration)
await click({ uid: "wide-rect-uid", element: "Wide function bar" });
await take_screenshot({ filePath: "PerfRuns/current/screenshots/flamegraph_zoomed.png" });

// 4. Reset and capture overview
await click({ uid: "reset-zoom-uid", element: "Reset zoom" });
await take_screenshot({
  filePath: "PerfRuns/current/screenshots/flamegraph_overview.png",
  fullPage: true
});
```

**When to use**:
- Quick, portable visualization
- Standard format from cargo-flamegraph
- No server needed (just `file://`)
- Hover tooltips with sample counts
- Lightweight sharing (single SVG file)

---

## Best Practices for Interactive Exploration

### 1. Always Take Snapshot First
Understand UI structure before clicking:
```typescript
const snapshot = await take_snapshot();
// Inspect snapshot to find element UIDs for subsequent clicks
```

### 2. Extract Data via evaluate_script
Don't rely on screenshots for numbers:
```typescript
// ✅ GOOD - Extract structured data
const data = await evaluate_script({ function: `() => extractTopK()` });

// ❌ BAD - Screenshot and try to OCR (unreliable)
await take_screenshot({ filePath: "data.png" });
```

### 3. Keep Multiple Views
Compare different perspectives:
```typescript
// Open multiple tabs for comparison
await new_page({ url: "https://www.speedscope.app/" });  // Tab 0
await new_page({ url: "https://profiler.firefox.com/from-file" });  // Tab 1

// Upload same profile to both
await select_page({ pageIdx: 0 });
await upload_file({ uid: "...", filePath: "profile.json" });
await select_page({ pageIdx: 1 });
await upload_file({ uid: "...", filePath: "profile.json" });

// Compare views side-by-side
```

### 4. Document the Exploration Path
Take screenshots at each step:
```typescript
const steps = [
  "overview",
  "call_tree",
  "flamegraph",
  "hotspot_zoomed",
  "sandwich_view"
];

for (const step of steps) {
  // Navigate to view
  await take_screenshot({ filePath: `PerfRuns/current/screenshots/${step}.png` });
}
```

### 5. Use wait_for for Stability
Ensure UI is ready before interacting:
```typescript
await wait_for({ text: "Call Tree" });  // Wait for specific text
await wait_for({ text: "100%" });       // Wait for loading complete
```

### 6. Handle Timeouts Gracefully
UIs may be slow; respect `browser_timeout_ms`:
```typescript
try {
  await wait_for({ text: "Loaded", timeout: config.browser_timeout_ms });
} catch (e) {
  console.warn("Browser timeout, falling back to CLI analysis");
  // Fall back to xctrace export or sample output
}
```

### 7. Close Tabs When Done
Free resources:
```typescript
// After extracting all data from a profile
await close_page({ pageIdx: 0 });
```

### 8. Validate Extractions
Check that `evaluate_script` returns expected format:
```typescript
const data = await evaluate_script({ function: extractTopK });
if (!Array.isArray(data) || data.length === 0) {
  console.error("Failed to extract Top-K, UI may have changed");
  // Retry with alternative selector or fall back
}
```

## Agent-Specific Workflow Constraints

### Time Budgets
- **Profile capture**: <30s (controlled by `xctrace_seconds`, `sample_seconds`)
- **Browser page load**: <30s (controlled by `browser_timeout_ms`)
- **Total investigation**: <5 minutes for standard queries

### Browser Lifecycle
- **Open**: Only when interactive exploration adds value over CLI
- **Keep alive**: During related follow-up questions
- **Close**: After extracting all needed data and screenshots

### Sudo Operations
- Request user approval for `footprint`, `fs_usage`, `powermetrics`
- Show exact command before execution
- Time-box to configured limits

### Parallel Profiling
- **Never** run multiple `xctrace` sessions simultaneously (conflicts)
- **OK** to open multiple browser tabs with different profiles
- **OK** to run `sample` while browser is exploring a previous run

### Error Recovery
```typescript
// If browser automation fails, fall back gracefully
try {
  const data = await browserExtractTopK();
} catch (browserError) {
  console.warn("Browser extraction failed, falling back to CLI");
  const data = await cliExtractTopK();  // Use xctrace export or parse sample output
}
```

## Privacy & Security

### Allow-Listed Origins
Only permit navigation to:
- `profiler.firefox.com`
- `ui.perfetto.dev`
- `www.speedscope.app`
- `file://` (local SVG/HTML files)

For documentation lookups:
- `docs.rs`
- `rust-lang.org`
- `github.com`
- `brendangregg.com`

### No Persistent Storage
- Run browsers in fresh contexts
- No cookies, localStorage, or cache persistence
- Each session is isolated

### Local-First
- Prefer `file://` for offline profiling
- Web UIs (Firefox Profiler, Perfetto) don't upload by default
- Verify network requests if paranoid: `list_network_requests()`

### Time-Boxing
- All captures use configured limits (`xctrace_seconds`, etc.)
- Browser interactions timeout after `browser_timeout_ms`
- Prevents runaway processes

---

**See also**:
- `perf-engineer.md` - Main skill overview
- `perf-tools-reference.md` - CLI tool catalog
- `perf-playbooks.md` - Question-specific investigation guides
