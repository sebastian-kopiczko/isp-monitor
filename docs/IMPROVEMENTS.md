# Dashboard improvement recommendations

> Critical review of the v2 `dashboard.html` and the case for v3.
> Companion document: `V3_PLAN.md` (concrete execution plan).

## Current state (v2)

- **Server**: `server.py` — Python `http.server`, serves `dashboard.html` and `/api/data` (aggregates `logs/*.jsonl`).
- **UI**: `dashboard.html` — single-file HTML + Chart.js + vanilla JS, ~700 lines.
- **Layout** top-down:
  1. Header (filters: ISP, label, time window, auto-refresh)
  2. **Latest status** panel (traffic-light cells, overall health badge, 5 workload verdict pills)
  3. 📖 Glossary (collapsible) — per-metric definitions, thresholds, caveats, smoke-test explainer
  4. ISP comparison (visible when ≥2 ISPs detected)
  5. KPI row (window medians + p10/p90)
  6. Four line charts: throughput, RTT to anchors, bufferbloat, jitter
  7. Per-workload pass-rate grid (label × workload)
  8. Sortable runs table
- **Style**: white cards on a `#f4f5f7` background, system fonts, light shadows, Sasha-Trubetskoy seaborn-ish color palette. Direction badges (▲ Higher / ▼ Lower) on charts and KPIs.
- **AI integration**: zero.

## Honest critique

1. **Functional but visually flat.** Looks like a Tableau template circa 2015. Information is dense; visual hierarchy is weak beyond font size.
2. **Shows numbers, doesn't think.** The data is rich and structured; the dashboard delegates 100% of interpretation to the user.
3. **Default line charts everywhere is lazy.** Four parallel time-series charts is "I had data, I plotted it." Most real questions ("is this connection better than that one?", "what's normal?") are distribution-shaped, not trend-shaped.
4. **No motion, no aesthetic identity.** Modern monitoring (Linear, Vercel Analytics, PostHog, Grafana 11) treats motion as semantic: pulses on update, animated state transitions, hero elements that draw the eye. Currently every refresh redraws silently.
5. **Bufferbloat chart is the worst offender.** A user sees "32 ms" with no visual context for whether that's grade A or C. The grading bands (5/30/60/200/400) are documented in the glossary but invisible on the chart.
6. **The big table at the bottom is a kitchen sink.** 16 columns, mostly redundant with the charts above.
7. **No "what should I do" output.** Result-oriented users want answers; we give them columns.

## Top 3 recommendations

### 1. AI diagnosis & narrative panel — *biggest impact, smallest risk*

Add a "Network Health Assistant" section. Send the last N hours of JSON to Claude API; render the response.

Capabilities to ship in v3:

- **Daily/weekly narrative.** "Play-wifi failed gaming 80% of the time this week, all jitter-driven. Bufferbloat hit grade C at 19:00 on Tuesday and Friday — consistent with evening neighbor congestion."
- **On-demand Q&A box.** Free-text input → context + question → Claude → answer rendered inline. "Why was upload slow at 14:00 yesterday?" / "Is my connection good enough for streaming 4K + video calls simultaneously?"
- **Auto-surfaced anomalies.** Red dot on a chart with a one-line LLM caption, e.g. "RTT spike at 16:42 — likely wifi interference; check device proximity."
- **Recommendations.** "Your ethernet sample is small (3 runs). Run 10+ on each medium before drawing ISP conclusions."

Why this is the highest-leverage move:
- Uses data we already have. No new collection.
- Turns a passive display into an active tool.
- Cost: a few cents/day in Claude API calls at reasonable cadence.
- Doesn't replace any existing functionality — strictly additive.

### 2. Distribution-aware visualizations — *use the right chart per question*

Replace generic line charts with the chart type that actually fits the question:

| Question | Wrong chart (now) | Right chart (v3) |
|---|---|---|
| "How does ISP A compare to ISP B?" | Two overlapping line traces | Ridgeline / violin / box plots side-by-side. Reveals distribution shape, not just medians. |
| "How bad is my bufferbloat?" | Line chart of ms values | Same chart with **A/B/C/D/F background bands** colored. The value lands in a visible zone. |
| "When does my connection get worse?" | Currently invisible | Day-of-week × hour heatmap. Color = pass-rate. Reveals evening-congestion patterns. |
| "What's the trend right now?" | Full line chart | **Sparklines in KPI cards.** Instant trend signal at-a-glance, full chart below for drill-down. |
| "How variable is each metric?" | Hidden in min/max columns | Inline mini-distribution in the table cells (Datadog-style). |

Net effect: more information per pixel, less cognitive load.

### 3. Modern aesthetic — *developer tool, not consultant deck*

Take cues from Linear, Vercel Analytics, PostHog, Grafana 11:

- **Dark mode default.** Toggle to light. Strategic single accent (lime, electric blue, or magenta) instead of 6-color seaborn palette.
- **Typography hierarchy.** Monospace numerics (`Berkeley Mono`, `JetBrains Mono`, or system `ui-monospace`); sans-serif labels; strong size contrast between hero/section/label.
- **Motion with meaning.** Sparkline pulses when a new run lands. Status badge cross-fades on state change. Sub-second number tween on KPI update. Toast in the corner when monitor.sh adds a run.
- **One hero element.** A big rotating-ring or gradient orb for overall health, replacing the slightly-flat HEALTHY/ISSUES badge. Glance from across the room and know the answer.
- **Glass / subtle gradients** instead of flat-card-on-gray. Doesn't have to scream Apple — just enough to feel premium.

Cost: ~1 day of CSS + small motion library (or hand-rolled CSS animations). Triples the perceived quality.

## Honorable mention: statistical rigor in comparisons

When Netia logs arrive, the current dashboard shows medians side-by-side. v3 should frame them statistically:

> *"With 47 runs each, Play's median upload is 12 Mbps higher than Netia's, but the distributions overlap heavily (Cohen's d = 0.3). The difference is statistically present but practically small."*

Most developers don't have intuition for "90 Mbps vs 78 Mbps" in noise terms. An explicit framing fixes that. Easy LLM integration — pass the two distributions, ask for a plain-English comparison with confidence.

## Things *not* to break

- v2 dashboard works. Don't regress it on the way to v3.
- The JSON schema (`version: 2`) is stable. Don't change it; if v3 needs new fields, bump to `version: 3` and make the schema backward-compatible.
- The append-only `logs/*.jsonl` model is good. Don't move to a database.
- The Python `http.server` is intentionally minimal. Stick with stdlib for the server side; complexity goes into the UI.
- Performance: the dashboard already handles 100+ runs. Make sure it stays responsive at 1000+ (one ISP, one medium, every 30 min for a year = ~17k runs).
