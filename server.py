#!/usr/bin/env python3
"""
isp-monitor dashboard server.

Serves dashboard.html, /api/data (run aggregation), and /api/diagnose +
/api/diagnose/latest (Claude-powered Network Health Assistant).

Usage:  python3 server.py                   # listens on http://127.0.0.1:8765
        PORT=9000 python3 server.py
        ANTHROPIC_API_KEY=... python3 server.py   # enables /api/diagnose

The diagnose endpoint requires the `anthropic` package and ANTHROPIC_API_KEY.
Without them, the endpoint responds with a graceful config-hint and the rest
of the server keeps working.
"""
import hashlib
import http.server
import json
import os
import socketserver
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOGS = ROOT / "logs"
ENV_FILE = ROOT / ".env"


def _load_env_file() -> None:
    """Load KEY=value pairs from .env into os.environ. Existing env wins.
    Stdlib-only: no python-dotenv dependency."""
    if not ENV_FILE.is_file():
        return
    for raw in ENV_FILE.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:]
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        v = v.strip()
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        # Don't clobber a real value already in env, but do replace empty/unset.
        if not os.environ.get(k):
            os.environ[k] = v


_load_env_file()

# Cache narratives so an auto-refreshing dashboard doesn't hit the API every poll.
# Free-text questions bypass this (question_hash distinguishes them).
DIAGNOSE_CACHE_TTL_SECONDS = 3600
_diagnose_cache: dict[str, tuple[float, dict]] = {}
_diagnose_cache_lock = threading.Lock()
_latest_narrative: dict | None = None  # last successful unprompted narrative

MODEL = "claude-opus-4-7"
MAX_WINDOW_HOURS = 24 * 7  # cost guard


def _load_runs() -> list[dict]:
    runs: list[dict] = []
    if not LOGS.is_dir():
        return runs
    for f in sorted(LOGS.glob("*.jsonl")):
        with open(f) as fp:
            for line in fp:
                line = line.strip()
                if not line:
                    continue
                try:
                    runs.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return runs


def _compact_run(r: dict) -> dict:
    """Strip noisy fields the model doesn't need (saves tokens)."""
    out = {
        "label": r.get("label"),
        "ts": r.get("ts"),
        "throughput": r.get("throughput"),
        "rtt_ms": r.get("rtt_ms"),
        "bufferbloat": r.get("bufferbloat"),
        "tls_rtt_avg_ms": r.get("tls_rtt_avg_ms"),
        "verdicts": r.get("verdicts"),
    }
    return {k: v for k, v in out.items() if v is not None}


def _window_runs(runs: list[dict], hours: int) -> list[dict]:
    if not runs:
        return []
    # runs are not guaranteed sorted by ts; sort defensively.
    sorted_runs = sorted(runs, key=lambda r: r.get("ts", ""))
    latest = sorted_runs[-1].get("ts", "")
    if not latest:
        return sorted_runs
    # naive cutoff via lexicographic compare on ISO timestamps (Z-suffix)
    from datetime import datetime, timedelta, timezone
    try:
        latest_dt = datetime.fromisoformat(latest.replace("Z", "+00:00"))
    except ValueError:
        return sorted_runs
    cutoff = latest_dt - timedelta(hours=hours)
    out = []
    for r in sorted_runs:
        ts = r.get("ts", "")
        if not ts:
            continue
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except ValueError:
            continue
        if dt >= cutoff:
            out.append(r)
    return out


SYSTEM_PROMPT = """You are analyzing benchmark data from a home internet quality monitor.

Each run is one JSON object with these fields (compact form shown to you):
- label: "<isp>-<medium>" e.g. "play-wifi" (ISP "play" over wifi)
- ts: ISO 8601 timestamp (UTC)
- throughput: {down_mbps, up_mbps} from a speedtest cycle
- rtt_ms: {anthropic, pl_local, eu_hub, us_east} each with {min, avg, max, jitter, loss_pct}
- bufferbloat: {idle_ms, loaded_ms, increase_ms, grade}  (grade A best, F worst)
- tls_rtt_avg_ms: average TLS handshake RTT
- verdicts: per-workload pass/fail strings for {claude, streaming_hd, streaming_4k, gaming, video_calls}

Verdict thresholds (already evaluated in the data — do not invent new ones):
- gaming: avg RTT to anthropic > 80ms OR jitter > 5ms OR bufferbloat increase > 30ms = FAIL
- video_calls: jitter > 15ms OR loss > 1% = FAIL
- streaming_hd: down_mbps < 25 = FAIL
- streaming_4k: down_mbps < 50 = FAIL
- claude: avg RTT to anthropic > 200ms OR jitter > 30ms = FAIL

Your job — produce a JSON object with three fields:

1. narrative: 2-3 sentences summarizing the most important pattern in the window.
   Reference specific labels and numbers. Be concrete. No moralizing.

2. anomalies: up to 3 entries. Each is {ts, summary, hypothesis}.
   ts = ISO timestamp of the anomalous run. summary = one line stating what spiked/dropped.
   hypothesis = one-line plausible cause. Skip if there are no real anomalies.

3. recommendations: up to 3 short, concrete, actionable items the user can do.
   Skip if data looks healthy.

Be specific. Reference numbers. If there's a free-text question, answer it directly
in the narrative field and keep anomalies/recommendations relevant to the question.
"""


OUTPUT_SCHEMA = {
    "type": "object",
    "properties": {
        "narrative": {"type": "string"},
        "anomalies": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "ts": {"type": "string"},
                    "summary": {"type": "string"},
                    "hypothesis": {"type": "string"},
                },
                "required": ["ts", "summary", "hypothesis"],
                "additionalProperties": False,
            },
        },
        "recommendations": {
            "type": "array",
            "items": {"type": "string"},
        },
    },
    "required": ["narrative", "anomalies", "recommendations"],
    "additionalProperties": False,
}


def _diagnose(window_hours: int, question: str | None) -> dict:
    """Call Claude. Returns a dict with narrative/anomalies/recommendations,
    plus _cached and _generated_at metadata."""
    global _latest_narrative

    try:
        import anthropic  # lazy — keeps server bootable without the SDK
    except ImportError:
        return {
            "error": "anthropic_sdk_missing",
            "message": "The `anthropic` Python package is not installed. Run `uv pip install anthropic` (or `pip install --break-system-packages anthropic`) and restart the server.",
        }
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return {
            "error": "api_key_missing",
            "message": "ANTHROPIC_API_KEY is not set. Export it and restart the server.",
        }

    window_hours = max(1, min(window_hours, MAX_WINDOW_HOURS))
    runs = _load_runs()
    window = _window_runs(runs, window_hours)
    if not window:
        return {
            "error": "no_data",
            "message": "No runs found in the requested window.",
        }
    compact = [_compact_run(r) for r in window]
    latest_ts = window[-1].get("ts", "")

    qh = hashlib.sha1((question or "").encode()).hexdigest()[:12]
    cache_key = f"{window_hours}:{hashlib.sha1(latest_ts.encode()).hexdigest()[:12]}:{qh}"

    cacheable = not question
    if cacheable:
        with _diagnose_cache_lock:
            entry = _diagnose_cache.get(cache_key)
            if entry and time.time() - entry[0] < DIAGNOSE_CACHE_TTL_SECONDS:
                out = dict(entry[1])
                out["_cached"] = True
                return out

    user_content = (
        f"Window: last {window_hours}h ({len(compact)} runs, latest {latest_ts}).\n"
        f"Question (optional): {question or '(none — generate the routine summary)'}\n\n"
        f"Runs (compact JSON, oldest first):\n{json.dumps(compact)}"
    )

    client = anthropic.Anthropic()
    try:
        resp = client.messages.create(
            model=MODEL,
            max_tokens=2048,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": user_content}],
            output_config={"format": {"type": "json_schema", "schema": OUTPUT_SCHEMA}},
        )
    except anthropic.APIStatusError as e:
        return {"error": "api_error", "message": f"{e.status_code}: {e.message}"}
    except anthropic.APIConnectionError as e:
        return {"error": "api_error", "message": f"network: {e}"}

    text = next((b.text for b in resp.content if b.type == "text"), "")
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return {"error": "parse_error", "message": "Model output was not valid JSON.", "raw": text}

    parsed["_cached"] = False
    parsed["_generated_at"] = int(time.time())
    parsed["_window_hours"] = window_hours
    parsed["_run_count"] = len(compact)
    parsed["_latest_ts"] = latest_ts

    if cacheable:
        with _diagnose_cache_lock:
            _diagnose_cache[cache_key] = (time.time(), {k: v for k, v in parsed.items() if k != "_cached"})
        _latest_narrative = parsed

    return parsed


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path.startswith("/api/data"):
            self._serve_data()
            return
        if self.path.startswith("/api/diagnose/latest"):
            self._serve_latest_diagnosis()
            return
        if self.path in ("/", "/index.html"):
            self.path = "/dashboard.html"
        return super().do_GET()

    def do_POST(self):  # noqa: N802
        if self.path.startswith("/api/diagnose"):
            self._serve_diagnose()
            return
        self.send_error(404, "Not found")

    def _serve_data(self):
        runs = _load_runs()
        self._json(200, {"runs": runs, "count": len(runs)})

    def _serve_latest_diagnosis(self):
        if _latest_narrative is None:
            self._json(200, {"narrative": None})
            return
        out = dict(_latest_narrative)
        out["_cached"] = True
        self._json(200, out)

    def _serve_diagnose(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        try:
            req = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid_json"})
            return
        window_hours = int(req.get("window_hours") or 24)
        question = (req.get("question") or "").strip() or None
        result = _diagnose(window_hours, question)
        status = 500 if result.get("error") in ("api_error", "parse_error") else 200
        self._json(status, result)

    def _json(self, status: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # silence default access log
        pass


def main():
    os.chdir(ROOT)
    port = int(os.environ.get("PORT", "8765"))
    with socketserver.TCPServer(("127.0.0.1", port), Handler) as srv:
        url = f"http://127.0.0.1:{port}/"
        print(f"isp-monitor dashboard: {url}", file=sys.stderr)
        print(f"data source: {LOGS}/*.jsonl", file=sys.stderr)
        if not os.environ.get("ANTHROPIC_API_KEY"):
            print("note: ANTHROPIC_API_KEY not set — /api/diagnose will return a config hint", file=sys.stderr)
        print("ctrl-c to stop", file=sys.stderr)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nshutting down", file=sys.stderr)


if __name__ == "__main__":
    main()
