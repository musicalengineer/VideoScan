#!/bin/bash
# tb5_diag.sh — "test TB 5 connection": strong yes/no on a Thunderbolt 5
# link between this Mac and a peer (default: ricksm5.local).
#
#   ./tb5_diag.sh [peer-ssh-host]
#
# Checks, in order:
#   1. TB link present + negotiated speed (expect 80 Gb/s for TB5)
#   2. Thunderbolt Bridge up with IPs on both ends
#   3. RTT over the bridge (expect < 1 ms)
#   4. TCP throughput BOTH directions (4 GB each way; PASS ≥ 30 Gbit/s,
#      STRONG ≥ 55 Gbit/s — the 2026-07-06 short-cable baseline was 67)
#
# Uses /usr/bin/python3 on BOTH ends deliberately: Apple-signed python is
# exempt from macOS 26 Local Network privacy, so this diag never trips
# the TCC Errno-65 trap that blocked the MLX venv python (2026-07-06).
set -u
PEER="${1:-ricksm5.local}"
PORT=5299
PY=/usr/bin/python3
pass=0; fail=0; warns=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
warn() { echo "  ⚠️  $1"; warns=$((warns+1)); }

echo "━━ TB5 diagnostic: $(hostname -s) ↔ $PEER ━━"

# 1. Link + speed --------------------------------------------------------
LINK=$(system_profiler SPThunderboltDataType 2>/dev/null \
       | grep -B1 -A3 "Status: Device connected" | grep -m1 "Speed:" \
       | grep -oE "[0-9]+ Gb/s")
if [ -z "${LINK}" ]; then
    bad "No Thunderbolt device connected on any bus (check cable seating)"
else
    case "$LINK" in
        "80 Gb/s"|"120 Gb/s") ok "TB link up at $LINK (full Thunderbolt 5)" ;;
        "40 Gb/s") warn "TB link up at $LINK — TB3/4 speed. Cable not TB5-rated or too long (passive limit ≈1 m; use active TB5 for longer runs)"; pass=$((pass+1)) ;;
        *) warn "TB link up at unusual speed: $LINK"; pass=$((pass+1)) ;;
    esac
fi

# 2. Bridge IPs -----------------------------------------------------------
MYIP=$(ifconfig bridge0 2>/dev/null | awk '/inet /{print $2; exit}')
PEERIP=$(ssh -o ConnectTimeout=8 "$PEER" \
         "ifconfig bridge0 2>/dev/null | awk '/inet /{print \$2; exit}'" 2>/dev/null)
if [ -n "$MYIP" ] && [ -n "$PEERIP" ]; then
    ok "Thunderbolt Bridge up: local $MYIP ↔ peer $PEERIP"
else
    bad "Thunderbolt Bridge missing an IP (local='$MYIP' peer='$PEERIP')"
    echo "━━ verdict: NO — link layer incomplete ━━"; exit 1
fi

# 3. RTT ------------------------------------------------------------------
RTT=$(ping -c 5 -t 5 "$PEERIP" 2>/dev/null | awk -F/ '/round-trip/{print $5}')
if [ -n "$RTT" ]; then
    awk -v r="$RTT" 'BEGIN{exit !(r < 1.0)}' \
        && ok "RTT ${RTT} ms" || warn "RTT ${RTT} ms (expected < 1 ms on TB)"
else
    bad "Peer bridge IP does not answer ping"
fi

# 4. Throughput both directions ------------------------------------------
GB=4
recv_py='
import socket, time, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(1); s.settimeout(30)
c, _ = s.accept()
n = 0; t0 = time.time()
while True:
    b = c.recv(4 << 20)
    if not b: break
    n += len(b)
t = time.time() - t0
print(f"{n*8/t/1e9:.1f}")
'
send_py='
import socket, sys, time
s = socket.socket(); s.settimeout(30)
s.connect((sys.argv[1], int(sys.argv[2])))
buf = b"\0" * (4 << 20)
sent = 0
while sent < int(sys.argv[3]) * 2**30:
    s.sendall(buf); sent += len(buf)
s.close()
'
throughput() {  # $1 = direction label, $2 = gbit/s value
    local dir="$1" v="$2"
    if [ -z "$v" ]; then bad "$dir: transfer failed"; return; fi
    if awk -v x="$v" 'BEGIN{exit !(x >= 55)}'; then ok "$dir: ${v} Gbit/s (strong — TB5 class)"
    elif awk -v x="$v" 'BEGIN{exit !(x >= 30)}'; then ok "$dir: ${v} Gbit/s (pass)"
    elif awk -v x="$v" 'BEGIN{exit !(x >= 8)}';  then warn "$dir: ${v} Gbit/s — TB but degraded (bad/long cable?)"
    else bad "$dir: ${v} Gbit/s — this is not Thunderbolt-class (traffic may be routing over Wi-Fi/Ethernet)"; fi
}

# 4a. this Mac → peer
ssh "$PEER" "$PY -c '$recv_py' $PORT" > /tmp/tb5diag_rx.$$ 2>/dev/null &
RXPID=$!
sleep 1
$PY -c "$send_py" "$PEERIP" $PORT $GB 2>/dev/null
wait $RXPID
throughput "TX  $(hostname -s) → peer" "$(cat /tmp/tb5diag_rx.$$ 2>/dev/null)"
rm -f /tmp/tb5diag_rx.$$

# 4b. peer → this Mac
$PY -c "$recv_py" $PORT > /tmp/tb5diag_rx2.$$ 2>/dev/null &
RXPID=$!
sleep 1
ssh "$PEER" "$PY -c '$send_py' $MYIP $PORT $GB" 2>/dev/null
wait $RXPID
throughput "RX  peer → $(hostname -s)" "$(cat /tmp/tb5diag_rx2.$$ 2>/dev/null)"
rm -f /tmp/tb5diag_rx2.$$

# Verdict -----------------------------------------------------------------
echo
if [ $fail -gt 0 ]; then
    echo "━━ verdict: NO — $fail check(s) failed ━━"; exit 1
elif [ $warns -gt 0 ]; then
    echo "━━ verdict: DEGRADED — link works but is NOT full TB5 ($warns warning(s)); not suitable for RDMA/cluster ━━"; exit 2
else
    echo "━━ verdict: YES — full Thunderbolt 5, cluster-grade ($pass checks passed) ━━"
fi
