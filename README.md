# isp-monitor

Bash benchmark + monitor for home internet quality. Compares ISPs and connection types (ethernet vs wifi) across workloads: Claude/agents, streaming, gaming, video calls.

## What it measures

- **Throughput** — down + up bandwidth (Mbps) via `speedtest`/`speedtest-cli`
- **RTT** to 4 anchor targets, in parallel:
  - `anthropic` — `api.anthropic.com` (Anthropic's own anycast edge)
  - `pl_local` — `wp.pl` (PL national baseline)
  - `eu_hub` — `s3.eu-central-1.amazonaws.com` (Frankfurt — where PL international traffic transits)
  - `us_east` — `s3.us-east-1.amazonaws.com` (true transatlantic transit)
- **Bufferbloat** — RTT under load minus idle RTT, graded A–F (Waveform scale). Single most important metric for gaming and video calls.
- **TLS handshake RTT** + 10 parallel-connection probe (Claude-style fan-out)
- **Per-workload verdicts**: `claude` / `streaming_hd` / `streaming_4k` / `gaming` / `video_calls` → OK / FAIL `<reason>` / UNKNOWN

One JSON line + one human-readable line per run, appended to `logs/<label>.jsonl` and `logs/<label>.txt`.

## Requirements

macOS or Linux. `bash` 3.2+, `python3`, `curl`, `ping`. Plus a speedtest CLI:

```bash
brew install speedtest-cli           # macOS
sudo apt install speedtest-cli       # Debian/Ubuntu
```

The script auto-detects the Ookla `speedtest` binary or the Python `speedtest-cli` (distinguished by `--version`, since Homebrew installs both names as symlinks to the Python tool).

## Usage

One-shot benchmark:

```bash
LABEL=ISP1-eth ./bench.sh
```

Continuous monitor (uses `caffeinate` to prevent idle sleep on macOS):

```bash
LABEL=ISP1-eth ./monitor.sh                  # 30-min interval default
LABEL=ISP1-eth INTERVAL=600 ./monitor.sh     # 10-min interval
```

`Ctrl-C` to stop. Switch network → change `LABEL` → start again. Each label writes its own log files.

`LABEL` is restricted to `[A-Za-z0-9._-]+`. `INTERVAL` is integer seconds, minimum 60.

## Output

Human one-liner per run:

```
[2026-05-26T09:19:36Z] ISP1-eth down=228.21 up=48.71 rtt-an=34.8 pl=37.4 eu=58.6 us=170.9 bloat=14.1(A) :: claude=OK 4k=OK hd=OK game=OK calls=OK
```

JSON schema (v2):

```json
{
  "version": 2,
  "label": "ISP1-eth",
  "ts": "2026-05-26T09:19:36Z",
  "throughput": {"down_mbps": 228.21, "up_mbps": 48.71},
  "rtt_ms": {
    "anthropic": {"min": ..., "avg": ..., "max": ..., "jitter": ..., "loss_pct": ...},
    "pl_local":  {...},
    "eu_hub":    {...},
    "us_east":   {...}
  },
  "bufferbloat": {"idle_ms": ..., "loaded_ms": ..., "increase_ms": ..., "grade": "A"},
  "tls_rtt_avg_ms": 86,
  "concurrent_tls": {"ok": 10, "total": 10},
  "speedtest": {"tool": "speedtest-cli", "server": "..."},
  "verdicts": {"claude": "OK", "streaming_hd": "OK", "streaming_4k": "OK", "gaming": "OK", "video_calls": "OK"}
}
```

## Live dashboard

```bash
python3 server.py    # http://127.0.0.1:8765/
```

Reads every `logs/*.jsonl` file and polls itself every 30s. KPI cards, line charts (throughput, RTT, bufferbloat, jitter), per-workload pass-rate grid, sortable runs table. Filter by ISP, label, time window.

The dashboard auto-groups by **ISP** when it sees `<isp>-<medium>` labels — see naming convention below.

## Comparing across ISPs (or machines)

### Label naming convention

```
<isp>-<medium>
```

Examples: `play-eth`, `play-wifi`, `netia-eth`, `netia-wifi`, `tmobile-wifi`.

The dashboard derives the ISP from the prefix before the first hyphen, gives each ISP its own colour family (Play = blue, Netia = orange, etc.), and shows a side-by-side ISP comparison card row when ≥2 ISPs are present. Add more palettes by editing `ISP_PALETTES` in `dashboard.html`.

### Importing logs from another machine

```bash
# on the Netia machine: run the monitor as normal
LABEL=netia-eth ./monitor.sh

# then copy its .jsonl files into THIS machine's logs/ directory:
scp netia-machine:~/isp-monitor/logs/netia-*.jsonl ./logs/
# or with rsync:
rsync -av netia-machine:~/isp-monitor/logs/netia-*.jsonl ./logs/
```

The dashboard picks them up on the next poll — no restart needed. `version` field in each JSON line means v1 and v2 lines can coexist if you ever mix them.

### Diagnostic guide

Once you have both ISPs side-by-side, look at the four RTT columns:

- Worse on **all 4 RTT targets** → ISP B's local link is just slower
- Worse on **anthropic + eu_hub + us_east**, fine on **pl_local** → ISP B has weaker international peering
- Worse on **only anthropic** → ISP B's anycast routing sends you to a more distant Anthropic POP
- Higher **bufferbloat** on ISP B → its CPE has worse queueing under load; affects gaming and calls most

## Comparing runs from the command line

```bash
cat logs/*.txt | sort                                          # all human lines
python3 -m json.tool --json-lines < logs/play-eth.jsonl        # pretty JSON
```

## Workload thresholds

| Workload | Pass criteria |
|---|---|
| `streaming_hd` | `down_mbps >= 5` |
| `streaming_4k` | `down_mbps >= 25` AND `anthropic.loss_pct < 1` |
| `video_calls` | `down/up >= 5`, anycast jitter `< 30` ms, loss `< 1%` |
| `gaming` | EU-hub RTT `< 80` ms, EU-hub jitter `< 5` ms, bufferbloat `< 30` ms |
| `claude` | `up_mbps >= 20`, anycast loss `< 1%`, anycast RTT `< 200` ms |

## Notes

- Each run uses ~300 MB (full-duplex speedtest). At the default 30-min interval that's ~14 GB/day. Fine on unmetered home internet; expensive on mobile/tethering.
- `speedtest` typically picks a PL-local server, so `throughput` reflects your last-mile, not international transit. The four RTT targets are the international-transit signal.
- On macOS the lid must stay open. `caffeinate` prevents idle sleep but not lid-close sleep unless an external display is attached.
- No AI tokens are consumed — `curl` hits `api.anthropic.com` unauthenticated.
