#!/usr/bin/env bash
# isp-monitor — loop bench.sh on an interval, keep macOS awake via caffeinate
# usage:  LABEL=ISP1-eth ./monitor.sh           # 30 min interval (default)
#         LABEL=ISP1-eth INTERVAL=600 ./monitor.sh
#         ./monitor.sh ISP1-eth 600             # positional form
set -u -o pipefail
LABEL="${LABEL:-${1:-unlabeled}}"
INTERVAL="${INTERVAL:-${2:-1800}}"   # seconds; default 30 min
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$SCRIPT_DIR/bench.sh"

if ! [[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: LABEL must match [A-Za-z0-9._-]+ (got: '$LABEL')" >&2
  exit 2
fi
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 60 ]; then
  echo "error: INTERVAL must be an integer >= 60 seconds (got: '$INTERVAL')" >&2
  exit 2
fi
if [ ! -x "$BENCH" ]; then
  echo "error: $BENCH not executable. run: chmod +x $BENCH" >&2
  exit 1
fi

# Heads-up about data cost. v2 runs full-duplex speedtest (down + up) to
# support the streaming/calls workloads + bufferbloat measurement.
# Detect by --version, not binary name — homebrew installs the Python tool
# under BOTH `speedtest` and `speedtest-cli`.
if command -v speedtest >/dev/null 2>&1 && speedtest --version 2>&1 | grep -qi ookla; then
  echo "isp-monitor: using Ookla speedtest (~400 MB per run, full duplex). At interval=${INTERVAL}s that is ~$(( 86400 / INTERVAL * 400 / 1024 )) GB/day." >&2
elif command -v speedtest-cli >/dev/null 2>&1 || command -v speedtest >/dev/null 2>&1; then
  echo "isp-monitor: using Python speedtest-cli (~300 MB per run, full duplex). At interval=${INTERVAL}s that is ~$(( 86400 / INTERVAL * 300 / 1024 )) GB/day." >&2
else
  echo "isp-monitor: warning, no speedtest tool found — throughput will be null" >&2
fi

# keep system awake until this shell exits; caffeinate dies with us.
# -i: no idle sleep   -m: no disk idle sleep   -s: no system sleep (AC only)
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -ims -w $$ &
  echo "isp-monitor: caffeinate active (no system sleep while this runs; plug in AC for -s to take effect)" >&2
else
  echo "isp-monitor: warning, caffeinate not found — system may sleep" >&2
fi

echo "isp-monitor: label=$LABEL interval=${INTERVAL}s logs=$SCRIPT_DIR/logs/"
echo "isp-monitor: press ctrl-c to stop"
trap 'echo; echo "isp-monitor: stopped at $(date -u +%Y-%m-%dT%H:%M:%SZ)"; exit 0' INT TERM

ITER=0
while true; do
  ITER=$((ITER+1))
  echo
  echo "--- run #$ITER at $(date -u +%Y-%m-%dT%H:%M:%SZ) ---"
  LABEL="$LABEL" "$BENCH"
  echo "next run in ${INTERVAL}s..."
  sleep "$INTERVAL"
done
