# Dashboard Style Guide

> Mission Control / NASA Ops — designed for at-a-glance monitoring of AI agents and tasks.

**Live previews:** Open `docs/rendered/design-system.html` and `docs/rendered/dashboard-mockup.html` in a browser to see the design system and full dashboard mockup.

## Design Philosophy

The dashboard is a **bird's-eye mission control screen**. The user should be able to glance at it and instantly know:

- How many agents are running and what they're doing
- Which tasks are queued, active, completed, or failed
- Whether budget is healthy or approaching limits
- If anything needs attention (errors, budget warnings, offline resources)

Dense information, not decorative whitespace. Every element earns its space.

## Typography

| Role | Font | Usage |
|------|------|-------|
| Display / Headers | **Space Mono** (400, 700) | Page titles, panel headers, metric values. Uppercase with letter-spacing for headers. |
| Body / UI | **IBM Plex Sans** (300–700) | Table cells, descriptions, nav items, form labels. Readable at 11–15px. |
| Data / Code | **IBM Plex Mono** (400, 500) | SSH commands, costs, timestamps, IPs, terminal output, budget values. |

Load via Google Fonts:
```
Space Mono:wght@400;700
IBM Plex Sans:wght@300;400;500;600;700
IBM Plex Mono:wght@400;500
```

### Size Scale

| Size | Use |
|------|-----|
| 28–32px | Metric values (Space Mono bold) |
| 20px | Page titles |
| 13–15px | Body text, table cells |
| 11–12px | Panel headers (Space Mono uppercase), data values, badges |
| 9–10px | Column headers, section labels (uppercase, letter-spacing 1.5–2px) |

## Color Palette

### CSS Variables

```css
:root {
  --bg:          #0a0e17;  /* Deep Space — page background */
  --surface:     #111827;  /* Dark Navy — panels, sidebar, cards */
  --surface-hi:  #1e293b;  /* Slate — elevated panels, borders */
  --border:      #1e293b;  /* Faint Slate — dividers */

  --green:       #22c55e;  /* Phosphor Green — primary accent */
  --amber:       #f59e0b;  /* Amber — warnings, budget */
  --cyan:        #06b6d4;  /* Cyan — info, links, SSH */
  --red:         #ef4444;  /* Signal Red — errors, critical */

  --text:        #e2e8f0;  /* Cool White — primary text */
  --muted:       #64748b;  /* Dim Gray — secondary text, labels */
}
```

### Color Semantics

| Color | Semantic Meaning |
|-------|-----------------|
| **Green** | Active/running agents, healthy heartbeats, success states, primary actions |
| **Amber** | Budget warnings, planning state, spot instance alerts, threshold approaching |
| **Cyan** | SSH commands, Tailscale IPs, informational links, secondary actions |
| **Red** | Errors, failed agents, critical budget exceeded, kill/stop actions |
| **White** | Neutral data (cost totals before threshold), primary text |
| **Muted** | Completed/inactive items, labels, timestamps, column headers |

## Components

### Metric Cards

Top-row stat cards with a 2px colored accent bar on top. Each card has:
- Label: uppercase, letter-spaced, muted (IBM Plex Mono 9–10px)
- Value: large number in accent color (Space Mono 28–32px bold)
- Subtitle: context line in muted (IBM Plex Mono 11px)

Color the accent bar to match the card's semantic meaning (green for agents, amber for queue, cyan for resources).

### Status Pills

Inline status indicators with a pulsing dot + label:
```
[● Running]  — green bg/text, pulsing dot
[● Planning] — amber bg/text
[● Queued]   — cyan bg/text
[● Error]    — red bg/text, fast pulse
[✓ Done]     — gray bg/text, no dot
```

Background: 10% opacity of the accent color. Border-radius: 3px.

### Progress Bars

Budget and progress tracking:
- Track: `--surface-hi` (#1e293b), 6px height, rounded
- Fill: accent color with matching `box-shadow` glow (0 0 6px)
- Green < 50%, Amber 50–80%, Red > 80% of cap

### Buttons

| Type | Style | Use |
|------|-------|-----|
| Primary | Green bg, black text | Spawn agent, primary CTA |
| Secondary | Transparent, cyan border | Copy SSH, view links |
| Ghost | Transparent, slate border | Config, filters |
| Danger | Transparent, red border | Stop agent, terminate |

Font: Space Mono 11px bold uppercase.

### Tables

Dense data tables for agent and task lists:
- Column headers: IBM Plex Mono 9px uppercase, letter-spacing 1.5px, muted color
- Row hover: subtle `--surface-hi` background
- Bottom borders: very faint (`rgba(30,41,59,0.5)`)
- Agent IDs: monospace, accent-colored based on status
- Costs: monospace amber
- Resources: monospace cyan

### Terminal Panel

Embedded terminal view for observing agent output:
- Dark background (`--bg`)
- Zellij-style tab bar with active tab highlighted green
- CRT scanline overlay (repeating-gradient, 2px transparent + 2px 4% black)
- Blinking green cursor with box-shadow glow
- Footer bar with resource info, cost, and action buttons (Copy SSH, Stop)

### Sidebar Navigation

Fixed left sidebar (220px):
- Active item: green text, green left-border with glow, green-tinted background
- Badges: monospace counts (green for active, amber for queued)
- Bottom status section: Tailscale connection, budget %, refresh interval

### Glow Effects

Accent colors get subtle glows via `box-shadow`:
```css
.dot-green { box-shadow: 0 0 6px rgba(34, 197, 94, 0.5); }
.bar-green { box-shadow: 0 0 6px #22c55e; }
```

Status dots pulse with a 2s ease-in-out animation (opacity 1 → 0.4 → 1).

## Layout Principles

1. **Sidebar + main** — fixed 220px sidebar, fluid main content
2. **Metrics row** — 4-column grid at top of every page
3. **2-column grid** — agents table + terminal panel (or detail + activity)
4. **3-column grid** — activity feed (span 2) + budget panel
5. **Sticky topbar** — page title, clock, spawn button always visible
6. **Responsive** — grid collapses to single column on iPad. Touch-friendly button sizes.

## Refresh Rates

| View | Interval |
|------|----------|
| Home overview | 30s |
| Agent list/detail | 5s |
| Task list | 5s |
| Resources | 10s |
| Costs | 30s |

Use SWR with `refreshInterval` for all polling.

## Accessibility

- All accent colors meet WCAG AA contrast on `--bg` and `--surface`
- No hover-only interactions (iPad support)
- Pulsing animations use `prefers-reduced-motion` media query to disable
- Status communicated by text + color (never color alone)
