#!/usr/bin/env python3
"""
isp-monitor dashboard server.

Serves dashboard.html and a /api/data endpoint that aggregates every JSONL
line in ./logs/. Run alongside ./monitor.sh; the dashboard polls /api/data
every 30s and re-renders, so new runs show up live.

Usage:  python3 server.py                   # listens on http://127.0.0.1:8765
        PORT=9000 python3 server.py
"""
import http.server
import json
import os
import socketserver
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOGS = ROOT / "logs"


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path.startswith("/api/data"):
            self._serve_data()
            return
        if self.path in ("/", "/index.html"):
            self.path = "/dashboard.html"
        return super().do_GET()

    def _serve_data(self):
        runs = []
        if LOGS.is_dir():
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
        body = json.dumps({"runs": runs, "count": len(runs)}).encode()
        self.send_response(200)
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
        print("ctrl-c to stop", file=sys.stderr)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nshutting down", file=sys.stderr)


if __name__ == "__main__":
    main()
