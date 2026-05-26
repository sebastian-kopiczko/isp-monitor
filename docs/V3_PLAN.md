# isp-monitor v3 — execution plan

> **Self-contained.** Read this first if you're picking up the project in a fresh session — it briefs you on the current state, the goals, the skill stack, and the ordered steps.

Companion doc: `IMPROVEMENTS.md` (the *why* — strategic critique and recommendations).

## TL;DR

Take the working v2 dashboard and ship three improvements in this order:

1. **AI diagnosis panel** (1–2 sessions) — biggest user value, smallest risk
2. **Distribution-aware viz** (2–3 sessions) — fixes the "lazy line charts" complaint
3. **Modern aesthetic + motion** (1–2 sessions) — makes it feel premium

Work on a `v3` branch; merge to `main` only when v3 is at parity + better than v2.

---

## Current-state recap (do not re-read the whole repo)

```
.
├── bench.sh           # one-shot benchmark, writes logs/<label>.{jsonl,txt}
├── monitor.sh         # loops bench.sh under caffeinate, validates args
├── server.py          # http.server, serves dashboard.html + /api/data
├── dashboard.html     # single-file UI: Chart.js + vanilla JS, ~700 lines
├── README.md          # user-facing docs
├── logs/              # JSONL data (gitignored)
└── docs/
    ├── IMPROVEMENTS.md
    └── V3_PLAN.md     # this file
```

**JSON schema (v2)** — one object per line in `logs/<label>.jsonl`:

```json
{
  "version": 2,
  "label": "play-wifi",                                 // "<isp>-<medium>"
  "ts":    "2026-05-26T09:23:40Z",
  "throughput": {"down_mbps": 245.2, "up_mbps": 49.5},
  "rtt_ms": {
    "anthropic": {"min":17,"avg":31,"max":101,"jitter":23,"loss_pct":0.0},
    "pl_local":  {...},
    "eu_hub":    {...},
    "us_east":   {...}
  },
  "bufferbloat": {"idle_ms":31,"loaded_ms":57,"increase_ms":26.2,"grade":"A"},
  "tls_rtt_avg_ms": 86,
  "concurrent_tls": {"ok":10,"total":10},
  "speedtest": {"tool":"speedtest-cli","server":"..."},
  "verdicts": {"claude":"OK","streaming_hd":"OK","streaming_4k":"OK","gaming":"FAIL jitter>5ms","video_calls":"OK"}
}
```

**v2 dashboard layout** (top-down): header filters → latest-status panel → glossary → ISP comparison → KPI medians → 4 line charts → verdict grid → table. See `dashboard.html` lines ~89–158 for the section structure.

---

## Skill stack — analysis & revised recommendation

The user shared a curated stack from skills.sh. Honest take per skill:

| Skill | Source | Installs | v3 fit | Use for |
|---|---|---|---|---|
| `anthropics/skills@canvas-design` | Anthropic official | 55.8K | **Strong** | Custom viz that Chart.js can't do cleanly — radial gauges, ridgeline plots, grade-band overlays, hero "health orb." |
| `pbakaus/impeccable@animate` | Community | 82.1K | **Strong** | Motion patterns for Phase 3 — sparkline pulse, status fade, hero ring animation. |
| `supercent-io/skills-template@log-analysis` | Community | 10.6K | **Marginal** | Our data is structured JSON, not raw logs. The skill is oriented at parsing/grepping. Only useful if doing local anomaly heuristics — but Phase 1 uses Claude API for that, so this is optional. |
| `yaklang/hack-skills@traffic-analysis-pcap` | Community | 699 | **Skip** | Wrong data type. We don't have pcaps. |
| `anthropics/knowledge-work-plugins@build-dashboard` | Anthropic official | 3.8K | **Keep** | Already installed. Useful for layout iteration in Phase 3. |
| `claude-api` | Anthropic official | n/a | **Critical** | Already in the environment. The whole AI diagnosis panel (Phase 1) needs this. **Missing from the curated list — but it's the most important one.** |

### Recommended stack to install before starting v3

```bash
# Phase 1 needs nothing new — claude-api is built in.

# Phase 2 + 3:
npx skills add anthropics/skills@canvas-design -g -y
npx skills add pbakaus/impeccable@animate -g -y

# Optional, only if Phase 1's LLM-based anomaly detection feels slow/expensive:
# npx skills add supercent-io/skills-template@log-analysis -g -y

# Do NOT install:
# - yaklang/hack-skills@traffic-analysis-pcap  (wrong data type)
# - nexu-io/open-design@live-dashboard         (66 installs, unproven)
# - owl-listener/designer-skills@data-visualization (617, unproven)
# - dylantarre/animation-principles@data-visualization (197, unproven)
# - oakoss/agent-skills@data-visualizer (53, unproven)
```

Rule of thumb: anything under ~5K installs is unproven; prefer the high-install or official skills when they cover the same territory.

---

## Phased plan

Each phase is independently shippable. Don't start phase N+1 until phase N is merged.

### Phase 0 — branch + smoke test (~10 min)

```bash
git checkout -b v3
# Sanity-check v2 still works after any rebase
python3 server.py &
curl -s http://127.0.0.1:8765/api/data | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['count'], 'runs OK')"
kill %1
```

Goal: confirm baseline before changing anything.

---

### Phase 1 — AI diagnosis panel

**Goal**: a "Network Health Assistant" section in the dashboard that reads the recent JSON and generates plain-English diagnosis, narrative, and recommendations.

**Skills used**: `claude-api` (built-in). No new dependencies.

**Architecture decision**: do the LLM call **server-side** (in `server.py`), not browser-side. Reasons:
- Keeps the API key off the client.
- Lets us cache responses (LLM output for the same data window doesn't need to regenerate every 30s).
- Lets us batch multiple questions into one call.

**New endpoints in `server.py`**:
- `POST /api/diagnose` → body: `{window_hours: 24, question: "<optional free text>"}` → response: `{narrative: "...", anomalies: [...], recommendations: [...], cached: bool}`
- `GET /api/diagnose/latest` → returns last cached narrative (cheap, used for periodic auto-refresh).

**Caching strategy**: cache by `(window_hours, hash(latest_ts), question_hash)`. TTL: 1 hour for unprompted narratives, no-cache for free-text Q&A.

**Suggested system prompt outline** (refine in the actual session):

```
You are reading benchmark data from a home internet quality monitor.
Schema described inline below. Your job:

1. Summarize the most important pattern in the data window in 2-3
   sentences. Reference specific labels (e.g. "play-wifi") and metrics.
2. Identify up to 3 anomalies (unexpected spikes/drops/loss events)
   with timestamp and one-line cause hypothesis.
3. Give up to 3 concrete recommendations the user can act on.

Be specific. Reference numbers from the data. Don't moralize about
internet usage. Do not invent thresholds; use the ones in the schema's
verdict logic.
```

Pass the **last N hours** of runs (compact JSON, drop the `speedtest.server` string, drop `concurrent_tls`), labels list, and verdict thresholds.

**UI**: a new card between status panel and ISP comparison:

```
┌─────────────────────────────────────────────────────────┐
│  🤖 Network Health Assistant                            │
│  ─────────────────────────────────────────────────────  │
│  [narrative paragraph here]                              │
│                                                          │
│  Anomalies                                               │
│    • 19:42 — RTT spike to 220ms (anthropic). Likely     │
│      wifi interference. Affected gaming verdict.         │
│    • ...                                                 │
│                                                          │
│  Recommendations                                         │
│    • Switch to ethernet for Claude work — your wifi     │
│      adds 22ms jitter consistently.                      │
│    • ...                                                 │
│                                                          │
│  Ask: [______________________________________] [Send]    │
└─────────────────────────────────────────────────────────┘
```

**Cost guard**: cap window at 7 days; cap context tokens; cache aggressively. Estimate: <$0.05/day at 30-min auto-refresh.

**Acceptance criteria**:
- Refresh on dashboard → narrative card populates within 5s on first load, instant on subsequent (cached).
- Ask box returns a relevant answer for "Why was upload slow at 14:00?" given a matching event in the data.
- If `ANTHROPIC_API_KEY` is unset, card shows a graceful "API key not configured" message instead of erroring.

**Files to touch**: `server.py` (add endpoints + LLM call), `dashboard.html` (add card + fetch logic).

---

### Phase 2 — distribution-aware visualizations

**Goal**: replace generic line charts with the right chart per question.

**Skills used**: `canvas-design` (for custom viz that Chart.js doesn't handle well).

**Concrete changes**:

1. **Bufferbloat chart** — add **horizontal grade bands** behind the line:
   - 0–5 ms (green) labeled `A+`
   - 5–30 ms (green) `A`
   - 30–60 ms (yellow) `B`
   - 60–200 ms (orange) `C`
   - 200–400 ms (red-orange) `D`
   - >400 ms (red) `F`
   - Implementable in Chart.js with the `annotation` plugin or a custom background plugin. No skill needed.

2. **ISP comparison** — replace the median-only cards with **ridgeline plots** (one row per ISP, x = metric value, y = density). Show throughput, RTT, bufferbloat side-by-side.
   - Chart.js doesn't do this natively. Two options:
     - Lightweight: kernel density estimate in JS, render as a stacked area chart per ISP.
     - Heavier: pull in D3.js (~50KB gzipped) just for this. Use `canvas-design` skill to draft the visual.
   - Recommend the first option unless ridgelines feel essential.

3. **Time-of-day heatmap** — new chart, `hour × day-of-week`, color = workload pass-rate (or RTT, configurable). Reveals evening-congestion patterns.
   - Pure HTML grid is fine; no library needed.

4. **Sparklines in KPI cards** — replace the static "median ↓ Mbps" cards with the same value + an embedded 24h sparkline.
   - Chart.js can do this with `pointRadius: 0, scales: { x: { display: false } }, plugins: { legend: { display: false } }` and a small canvas. Use the existing `chartjs-adapter-date-fns`.

5. **Mini-distributions in the runs table** — for `bloat` and `loss` columns, embed a 24-hour mini-histogram instead of just the latest number.
   - Optional; only do if there's session budget.

**Acceptance criteria**:
- Bufferbloat chart at a glance: I see a value, I see what grade-band it's in, no glossary lookup needed.
- ISP comparison shows distribution shape, not just point estimates.
- New heatmap reveals at least one previously-hidden pattern (test on real 7-day data).

**Files to touch**: `dashboard.html` only.

---

### Phase 3 — modern aesthetic & motion

**Goal**: take the dashboard from "consultant deck" to "developer tool I'd actually open."

**Skills used**: `impeccable@animate`, `canvas-design`, `build-dashboard`.

**Concrete changes**:

1. **Dark mode default** + toggle to light. Use CSS custom properties; flip a `[data-theme="light"]` attribute on `<html>`. Strategic single accent color (suggest: lime `#a3e635` or electric blue `#3b82f6`) replacing the seaborn palette.

2. **Typography overhaul**:
   - Numerics: `ui-monospace, "Berkeley Mono", "JetBrains Mono", monospace`.
   - Labels: keep system sans-serif.
   - Strong hierarchy: hero numbers in the status panel should be 32–40px, not 18px.

3. **Hero "health" element**: replace the current text badge with a rotating-ring SVG showing pass-rate (n of 5 verdicts OK). Animate the fill. This is the "look from across the room and know" feature.

4. **Motion with meaning**:
   - Sparklines pulse softly when `/api/data` returns a new run (use `requestAnimationFrame` + opacity tween).
   - Status badge cross-fades on state change (don't just swap class).
   - Sub-second tween on KPI numeric updates (interpolate from old to new).
   - Toast notification in the corner when monitor.sh adds a run ("✓ new run · play-wifi · ↓228 ↑49").

5. **Surfaces**: replace `background: #fff` cards on `#f4f5f7` bg with:
   - Dark mode: cards `#0a0a0a` with `#1a1a1a` borders on a `#000` bg.
   - Light mode: keep current.
   - Subtle gradient on the hero card.

**Acceptance criteria**:
- Dark mode loads by default, looks intentional.
- Hero ring animates state changes — visually compelling.
- New-data arrival is sensed peripherally (motion), not just by reading numbers.
- No visible jank (60fps animations, no layout-thrashing).

**Files to touch**: `dashboard.html` (heavy CSS rework, light JS for motion).

---

## Anti-goals — things explicitly *not* to do in v3

- **Don't add a database.** Append-only JSONL files are the right abstraction at this data volume.
- **Don't add a frontend framework.** Single-file HTML + vanilla JS is the simplicity contract. React/Vue/Svelte would be net-negative.
- **Don't break v2 schema.** `version: 2` data must still render. If a new field is needed, add it as optional, bump to `version: 3`.
- **Don't break the live-monitor workflow.** `monitor.sh` and `bench.sh` are stable; touch them only if v3 needs new fields, and even then with backward-compatible JSON.
- **Don't move the server to FastAPI/Flask.** stdlib `http.server` is enough. Complexity goes into the UI.
- **Don't ship Phase 3 without Phase 1.** Aesthetic improvements on a non-thinking dashboard is polish-on-the-wrong-thing. Phase 1 is the value; 3 is the showcase.

---

## Branching & commit hygiene

```bash
git checkout -b v3
# Commit per phase, small commits per concrete change. Examples:
#   "v3 phase 1: add /api/diagnose endpoint with Claude API call"
#   "v3 phase 1: render diagnosis card in dashboard"
#   "v3 phase 2: bufferbloat chart background grade bands"
#   "v3 phase 2: ridgeline plot for ISP comparison"
#   "v3 phase 3: dark mode + theme toggle"
#   "v3 phase 3: animated health ring"
# Merge v3 -> main only when all three phases pass acceptance criteria
# AND v2 features still render correctly with v2-only data.
```

Run before each commit:
```bash
bash -n bench.sh && bash -n monitor.sh && python3 -c "import ast; ast.parse(open('server.py').read())"
```

---

## Verification checklist before merging to main

- [ ] `python3 server.py` boots without warnings.
- [ ] `curl http://127.0.0.1:8765/api/data` returns valid JSON.
- [ ] Loading the dashboard with an empty `logs/` directory shows "no data" state, not an error.
- [ ] Loading with v1 and v2 log lines mixed: v2 renders, v1 lines are ignored (or rendered safely as best-effort).
- [ ] Phase 1: assistant card populates within 5s; works with `ANTHROPIC_API_KEY` missing (shows config hint).
- [ ] Phase 2: bufferbloat bands visible at a glance; ridgeline plot renders for ≥2 ISPs.
- [ ] Phase 3: dark mode loads by default; theme toggle persists across reload (`localStorage`); no console errors during motion.
- [ ] Performance: 1000 simulated runs in `logs/` don't slow first render >2s.

---

## Open questions to clarify on the way (flag, don't guess)

- **API key handling.** Put it in `.env` and load with stdlib, or require explicit env var? Likely just env var to keep the server stdlib-only.
- **Whether the assistant should write back to logs.** E.g. flagging an anomaly as "investigated" — feels feature-creepy for v3; defer.
- **Whether to add a `/api/raw` endpoint** for someone wanting to grab the whole dataset for analysis outside the dashboard. Cheap to add; flag for v3.5 if not in v3.
