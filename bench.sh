#!/usr/bin/env bash
# isp-bench v2 — multi-workload internet quality benchmark.
# Measures throughput (up+down), RTT to 4 anchor targets, bufferbloat (RTT
# under load), TLS handshake cost, and parallel-connection capacity.
# Grades the link for: Claude/agents, HD streaming, 4K streaming, gaming,
# and video calls. ~50s per run, single-line JSON appended to logs/.
# Bash 3.2 compatible (macOS system bash).

set -u -o pipefail

# Force C numeric locale: awk's %.1f respects locale and would emit "26,2"
# on PL/DE/etc. shells, breaking JSON validity and the grade reparse.
export LC_NUMERIC=C

LABEL="${LABEL:-${1:-unlabeled}}"
if ! [[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: LABEL must match [A-Za-z0-9._-]+ (got: '$LABEL')" >&2
  exit 2
fi
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${BENCH_LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$LOG_DIR"
JSON_LOG="$LOG_DIR/${LABEL}.jsonl"
TXT_LOG="$LOG_DIR/${LABEL}.txt"

TIMEOUT_CMD=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_CMD=timeout
[ -z "$TIMEOUT_CMD" ] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_CMD=gtimeout
maybe_timeout() {
  local secs=$1; shift
  if [ -n "$TIMEOUT_CMD" ]; then "$TIMEOUT_CMD" "$secs" "$@"
  else "$@"; fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Anchor targets (parallel indexed arrays — bash 3.2 lacks assoc arrays).
# Each tells you something different about the link:
#   anthropic = Anthropic's own anycast edge (the actual product endpoint)
#   pl_local  = baseline for last-mile + Polish backbone
#   eu_hub    = Frankfurt; where ~all PL international traffic transits
#   us_east   = true transatlantic transit (no CDN/anycast distortion)
TARGET_KEYS=(anthropic pl_local eu_hub us_east)
TARGET_HOSTS=("api.anthropic.com" "wp.pl" "s3.eu-central-1.amazonaws.com" "s3.us-east-1.amazonaws.com")
# Index constants for readability
K_ANTHROPIC=0; K_PL_LOCAL=1; K_EU_HUB=2; K_US_EAST=3

TLS_HOST="api.anthropic.com"
BUFFERBLOAT_HOST="wp.pl"   # close + stable; we already ping it for baseline

RTT_MIN=(null null null null)
RTT_AVG=(null null null null)
RTT_MAX=(null null null null)
RTT_JIT=(null null null null)
LOSS=(null null null null)

echo "=== isp-bench v2 :: label=$LABEL ===" >&2

# ---------- 1. Parallel idle pings to all targets (~15s) ----------
echo "[1/5] idle pings to 4 targets in parallel (~15s)..." >&2
for i in "${!TARGET_KEYS[@]}"; do
  k="${TARGET_KEYS[$i]}"
  h="${TARGET_HOSTS[$i]}"
  ( maybe_timeout 25 ping -c 30 -i 0.5 "$h" > "$TMPDIR/ping_$k.txt" 2>/dev/null || true ) &
done
wait

parse_rtt() {
  awk -F'[ =/]+' '/min\/avg\/max/ {for(i=1;i<=NF;i++) if($i=="ms"){print $(i-4), $(i-3), $(i-2), $(i-1); exit}}' "$1"
}
parse_loss() {
  awk -F', ' '/packet loss/ {for(i=1;i<=NF;i++) if($i ~ /loss/){split($i,a," "); gsub("%","",a[1]); print a[1]; exit}}' "$1"
}
for i in "${!TARGET_KEYS[@]}"; do
  k="${TARGET_KEYS[$i]}"
  mn=""; av=""; mx=""; jt=""
  read -r mn av mx jt <<<"$(parse_rtt "$TMPDIR/ping_$k.txt")" || true
  ls="$(parse_loss "$TMPDIR/ping_$k.txt")"
  RTT_MIN[$i]="${mn:-null}"
  RTT_AVG[$i]="${av:-null}"
  RTT_MAX[$i]="${mx:-null}"
  RTT_JIT[$i]="${jt:-null}"
  LOSS[$i]="${ls:-null}"
done

# ---------- 2. Speedtest (down+up) with concurrent bufferbloat ping (~25-30s) ----------
echo "[2/5] speedtest (down + up) + bufferbloat ping..." >&2

ST_BIN=""; ST_TOOL=none
# Detect by --version output, NOT binary name: homebrew installs the Python
# speedtest-cli formula symlinked under BOTH `speedtest` and `speedtest-cli`.
if command -v speedtest >/dev/null 2>&1 && speedtest --version 2>&1 | grep -qi ookla; then
  ST_BIN=speedtest; ST_TOOL=ookla
elif command -v speedtest-cli >/dev/null 2>&1; then
  ST_BIN=speedtest-cli; ST_TOOL=speedtest-cli
elif command -v speedtest >/dev/null 2>&1; then
  ST_BIN=speedtest; ST_TOOL=speedtest-cli
fi

UP_MBPS=null; DOWN_MBPS=null; ST_SERVER=unknown
LOADED_RTT_AVG=null
IDLE_RTT_AVG="${RTT_AVG[$K_PL_LOCAL]}"   # taken from step 1
BLOAT_MS=null; BLOAT_GRADE=null

if [ -n "$ST_BIN" ]; then
  # Start speedtest in background, full duplex (no --no-download).
  if [ "$ST_TOOL" = ookla ]; then
    ( maybe_timeout 40 "$ST_BIN" --format=json --progress=no --accept-license --accept-gdpr > "$TMPDIR/st.json" 2>/dev/null ) &
  else
    ( maybe_timeout 40 "$ST_BIN" --json > "$TMPDIR/st.json" 2>/dev/null ) &
  fi
  ST_PID=$!
  # Give speedtest ~2s to engage, then start the loaded ping
  sleep 2
  ( maybe_timeout 25 ping -c 30 -i 0.5 "$BUFFERBLOAT_HOST" > "$TMPDIR/loaded_ping.txt" 2>/dev/null || true ) &
  LOADED_PID=$!
  wait "$ST_PID" || true
  wait "$LOADED_PID" || true

  if [ "$ST_TOOL" = ookla ]; then
    UP_MBPS=$(python3 -c "import json;d=json.load(open('$TMPDIR/st.json'));b=d.get('upload',{}).get('bandwidth',0);print(round(b*8/1e6,2) if b else 'null')" 2>/dev/null || echo null)
    DOWN_MBPS=$(python3 -c "import json;d=json.load(open('$TMPDIR/st.json'));b=d.get('download',{}).get('bandwidth',0);print(round(b*8/1e6,2) if b else 'null')" 2>/dev/null || echo null)
    ST_SERVER=$(python3 -c "import json;d=json.load(open('$TMPDIR/st.json'));s=d.get('server',{});print((s.get('name','?')+'/'+s.get('location','?')).replace(chr(34),''))" 2>/dev/null || echo unknown)
  else
    UP_MBPS=$(python3 -c "import json;d=json.load(open('$TMPDIR/st.json'));u=d.get('upload',0);print(round(u/1e6,2) if u else 'null')" 2>/dev/null || echo null)
    DOWN_MBPS=$(python3 -c "import json;d=json.load(open('$TMPDIR/st.json'));u=d.get('download',0);print(round(u/1e6,2) if u else 'null')" 2>/dev/null || echo null)
    ST_SERVER=$(python3 -c "import json;d=json.load(open('$TMPDIR/st.json'));s=d.get('server',{});print((s.get('sponsor','?')+'/'+s.get('name','?')).replace(chr(34),''))" 2>/dev/null || echo unknown)
  fi

  _mn=""; _av=""; _mx=""; _jt=""
  read -r _mn _av _mx _jt <<<"$(parse_rtt "$TMPDIR/loaded_ping.txt")" || true
  LOADED_RTT_AVG="${_av:-null}"

  # Bufferbloat = loaded_avg - idle_avg (floored at 0). Graded per Waveform.
  if [ "$IDLE_RTT_AVG" != "null" ] && [ "$LOADED_RTT_AVG" != "null" ]; then
    BLOAT_MS=$(awk -v i="$IDLE_RTT_AVG" -v l="$LOADED_RTT_AVG" 'BEGIN{d=l-i; if(d<0)d=0; printf "%.1f", d}')
    BLOAT_GRADE=$(awk -v b="$BLOAT_MS" 'BEGIN{
      if (b<5) print "A+"; else if (b<30) print "A"; else if (b<60) print "B";
      else if (b<200) print "C"; else if (b<400) print "D"; else print "F"
    }')
  fi
fi

# ---------- 3. TLS handshake RTT (~3s) ----------
echo "[3/5] TLS handshake RTT x5 to $TLS_HOST..." >&2
TLS_SUM=0; TLS_N=0
for i in 1 2 3 4 5; do
  T=$(curl -s -o /dev/null --connect-timeout 5 --max-time 8 -w '%{time_appconnect}' "https://$TLS_HOST/" 2>/dev/null || echo 0)
  TLS_SUM=$(awk -v a="$TLS_SUM" -v b="$T" 'BEGIN{print a+b}')
  TLS_N=$((TLS_N+1))
done
TLS_AVG_MS=$(awk -v s="$TLS_SUM" -v n="$TLS_N" 'BEGIN{if(n && s>0) printf "%.0f", (s/n)*1000; else print "null"}')

# ---------- 4. Concurrent TLS probe (~5s) ----------
echo "[4/5] 10 parallel TLS handshakes..." >&2
CONC_OK=$(for i in $(seq 1 10); do
  curl -s -o /dev/null --connect-timeout 5 --max-time 10 -w '%{http_code}\n' "https://$TLS_HOST/" &
done | grep -c '^[2-5][0-9][0-9]$' || true)

# ---------- 5. Per-workload verdicts ----------
echo "[5/5] grading..." >&2
# Each verdict returns either "OK" or "FAIL <reasons>". UNKNOWN if data missing.
# Thresholds:
#   streaming_hd : down >= 5 Mbps
#   streaming_4k : down >= 25 Mbps AND loss < 1%
#   video_calls  : down >= 5, up >= 5, jitter < 30 ms, loss < 1%
#   gaming       : EU-hub RTT < 80 ms, jitter < 5 ms, bufferbloat < 30 ms
#   claude       : up >= 20 Mbps, loss < 1%, anycast RTT < 200 ms
grade() {
  awk -v workload="$1" \
      -v down="$DOWN_MBPS" -v up="$UP_MBPS" \
      -v rtt_an="${RTT_AVG[$K_ANTHROPIC]}" -v jit_an="${RTT_JIT[$K_ANTHROPIC]}" -v loss_an="${LOSS[$K_ANTHROPIC]}" \
      -v rtt_eu="${RTT_AVG[$K_EU_HUB]}"    -v jit_eu="${RTT_JIT[$K_EU_HUB]}" \
      -v bloat="$BLOAT_MS" '
  function n(v){ return (v!="null" && v!="") }
  BEGIN{
    msg=""; ok=1; unk=0
    if (workload=="streaming_hd") {
      if (!n(down)) {unk=1} else if (down+0<5) {msg=msg" down<5Mbps"; ok=0}
    } else if (workload=="streaming_4k") {
      if (!n(down)) unk=1; else if (down+0<25) {msg=msg" down<25Mbps"; ok=0}
      if (n(loss_an) && loss_an+0>1) {msg=msg" loss>1%"; ok=0}
    } else if (workload=="video_calls") {
      if (!n(down) || !n(up)) unk=1
      else {
        if (down+0<5) {msg=msg" down<5Mbps"; ok=0}
        if (up+0<5)   {msg=msg" up<5Mbps";   ok=0}
      }
      if (n(jit_an) && jit_an+0>30) {msg=msg" jitter>30ms"; ok=0}
      if (n(loss_an) && loss_an+0>1) {msg=msg" loss>1%"; ok=0}
    } else if (workload=="gaming") {
      if (!n(rtt_eu)) unk=1; else if (rtt_eu+0>80) {msg=msg" rtt-eu>80ms"; ok=0}
      if (n(jit_eu) && jit_eu+0>5)  {msg=msg" jitter>5ms"; ok=0}
      if (n(bloat) && bloat+0>30)   {msg=msg" bufferbloat>30ms"; ok=0}
      if (!n(bloat)) unk=1
    } else if (workload=="claude") {
      if (!n(up)) unk=1; else if (up+0<20) {msg=msg" up<20Mbps"; ok=0}
      if (n(loss_an) && loss_an+0>1) {msg=msg" loss>1%"; ok=0}
      if (n(rtt_an) && rtt_an+0>200) {msg=msg" rtt>200ms"; ok=0}
    }
    if (unk==1 && msg=="") print "UNKNOWN"
    else if (ok==1) print "OK"
    else print "FAIL" msg
  }'
}
V_STREAM_HD=$(grade streaming_hd)
V_STREAM_4K=$(grade streaming_4k)
V_GAMING=$(grade gaming)
V_CALLS=$(grade video_calls)
V_CLAUDE=$(grade claude)

# ---------- Assemble JSON (via python3 for safe quoting/null handling) ----------
export LABEL TS DOWN_MBPS UP_MBPS BLOAT_MS BLOAT_GRADE IDLE_RTT_AVG LOADED_RTT_AVG \
       TLS_AVG_MS CONC_OK ST_TOOL ST_SERVER \
       V_STREAM_HD V_STREAM_4K V_GAMING V_CALLS V_CLAUDE
for i in "${!TARGET_KEYS[@]}"; do
  k="${TARGET_KEYS[$i]}"
  export "RTT_MIN_$k=${RTT_MIN[$i]}"
  export "RTT_AVG_$k=${RTT_AVG[$i]}"
  export "RTT_MAX_$k=${RTT_MAX[$i]}"
  export "RTT_JIT_$k=${RTT_JIT[$i]}"
  export "LOSS_$k=${LOSS[$i]}"
done

JSON=$(python3 <<'PY'
import os, json
def num(s):
    if s in ("null", "", None): return None
    try:    return float(s) if "." in s else int(s)
    except: return None
def s(name): return os.environ.get(name, "")
def rtt_block(k):
    return {
      "min":      num(os.environ.get(f"RTT_MIN_{k}")),
      "avg":      num(os.environ.get(f"RTT_AVG_{k}")),
      "max":      num(os.environ.get(f"RTT_MAX_{k}")),
      "jitter":   num(os.environ.get(f"RTT_JIT_{k}")),
      "loss_pct": num(os.environ.get(f"LOSS_{k}")),
    }
d = {
  "version": 2,
  "label": s("LABEL"),
  "ts": s("TS"),
  "throughput": {"down_mbps": num(s("DOWN_MBPS")), "up_mbps": num(s("UP_MBPS"))},
  "rtt_ms": {k: rtt_block(k) for k in ("anthropic","pl_local","eu_hub","us_east")},
  "bufferbloat": {
    "idle_ms":     num(s("IDLE_RTT_AVG")),
    "loaded_ms":   num(s("LOADED_RTT_AVG")),
    "increase_ms": num(s("BLOAT_MS")),
    "grade":       s("BLOAT_GRADE") or None,
  },
  "tls_rtt_avg_ms": num(s("TLS_AVG_MS")),
  "concurrent_tls": {"ok": num(s("CONC_OK")), "total": 10},
  "speedtest": {"tool": s("ST_TOOL"), "server": s("ST_SERVER")},
  "verdicts": {
    "claude":       s("V_CLAUDE"),
    "streaming_hd": s("V_STREAM_HD"),
    "streaming_4k": s("V_STREAM_4K"),
    "gaming":       s("V_GAMING"),
    "video_calls":  s("V_CALLS"),
  },
}
print(json.dumps(d, separators=(',',':')))
PY
)

# ---------- Human one-liner ----------
HUMAN=$(printf '[%s] %s down=%s up=%s rtt-an=%s pl=%s eu=%s us=%s bloat=%s(%s) :: claude=%s 4k=%s hd=%s game=%s calls=%s' \
  "$TS" "$LABEL" \
  "$DOWN_MBPS" "$UP_MBPS" \
  "${RTT_AVG[$K_ANTHROPIC]}" "${RTT_AVG[$K_PL_LOCAL]}" "${RTT_AVG[$K_EU_HUB]}" "${RTT_AVG[$K_US_EAST]}" \
  "$BLOAT_MS" "$BLOAT_GRADE" \
  "$V_CLAUDE" "$V_STREAM_4K" "$V_STREAM_HD" "$V_GAMING" "$V_CALLS")

echo
echo "$HUMAN"
echo "$JSON"
echo "$JSON"  >> "$JSON_LOG"
echo "$HUMAN" >> "$TXT_LOG"
