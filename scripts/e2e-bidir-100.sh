#!/bin/bash
# Bidirectional 100-DM Stress Test: BPF Beam B ↔ Pager
# Sends 50 DMs from app (BPF-B) → Pager via debug HTTP
# Sends 50 DMs from Pager → BPF-B via meshtastic CLI over TCP
# Verifies all messages appear in app database + periodic UI screenshots
#
# Usage: ./scripts/e2e-bidir-100.sh [iphone_ip] [pager_ip]

set -euo pipefail

IPHONE="${1:-192.168.1.187}"
PAGER_IP="${2:-192.168.1.117}"
BASE="http://${IPHONE}:8765"
OUTDIR="/tmp/meshreliable-bidir100-$(date +%s)"
mkdir -p "$OUTDIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; }
info() { echo -e "${YELLOW}INFO${NC} $1"; }
header() { echo -e "\n${CYAN}======== $1 ========${NC}"; }
arrow_out() { echo -e "${BLUE}→→→${NC} $1"; }
arrow_in() { echo -e "${MAGENTA}←←←${NC} $1"; }

# ================================================================
# PRE-FLIGHT CHECKS
# ================================================================

info "Checking app connection..."
STATUS=$(curl -m 5 -s "$BASE/status" 2>/dev/null || echo '{}')
DEVICE_NUM=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deviceNum',0))" 2>/dev/null || echo 0)
CONN_STATUS=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")

if [ "$DEVICE_NUM" = "0" ] || [ "$CONN_STATUS" != "connected" ]; then
    fail "App not connected (status=$CONN_STATUS, device=$DEVICE_NUM)"
    exit 1
fi
DEVICE_HEX=$(python3 -c "print(f'!{${DEVICE_NUM}:08x}')")
pass "App connected to BPF Beam B: $DEVICE_NUM ($DEVICE_HEX)"

info "Checking pager connection..."
PAGER_INFO=$(meshtastic --host "$PAGER_IP" --info 2>&1 | head -5)
PAGER_NUM=$(echo "$PAGER_INFO" | python3 -c "
import sys, re
text = sys.stdin.read()
m = re.search(r'myNodeNum.*?(\d+)', text)
print(m.group(1) if m else '0')
" 2>/dev/null || echo "0")

if [ "$PAGER_NUM" = "0" ]; then
    fail "Cannot reach pager at $PAGER_IP"
    exit 1
fi
PAGER_HEX=$(python3 -c "print(f'!{${PAGER_NUM}:08x}')")
pass "Pager connected: $PAGER_NUM ($PAGER_HEX)"

echo ""
echo "================================================================"
echo "  BIDIRECTIONAL 100-DM STRESS TEST"
echo "  BPF Beam B ($DEVICE_HEX) ↔ Pager ($PAGER_HEX)"
echo "  Path: 144MHz ↔ MQTT relay ↔ sub-GHz"
echo "  Output: $OUTDIR"
echo "================================================================"
echo ""

# Navigate to Pager conversation
info "Navigating to Pager conversation..."
curl -m 5 -s -X POST "$BASE/action/navigate" \
    -H "Content-Type: application/json" \
    -d "{\"tab\":\"messages\",\"userNum\":$PAGER_NUM}" > /dev/null 2>&1
sleep 2

# Initial screenshot
curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/00_initial.png" 2>/dev/null
info "Initial screenshot saved"

# Counters
TOTAL=0
PASSED=0
FAILED=0
OUT_OK=0; OUT_FAIL=0    # BPF-B → Pager
IN_OK=0; IN_FAIL=0      # Pager → BPF-B

# ================================================================
# SEND FUNCTIONS
# ================================================================

# BPF-B → Pager (outgoing via debug HTTP)
send_outgoing() {
    local msg_num=$1
    local unique="OUT_${msg_num}_$(date +%s%N | tail -c 8)"
    TOTAL=$((TOTAL + 1))

    arrow_out "#$msg_num BPF-B → Pager: $unique"

    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-message" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$PAGER_NUM,\"text\":\"$unique\"}" 2>/dev/null || echo '{"error":"timeout"}')

    if echo "$RESULT" | grep -q '"ok":true'; then
        # Quick DB check
        sleep 1
        MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$PAGER_NUM&limit=3" 2>/dev/null || echo '[]')
        if echo "$MSGS" | grep -q "$unique"; then
            pass "#$msg_num OUT persisted in DB"
            PASSED=$((PASSED + 1))
            OUT_OK=$((OUT_OK + 1))
            return 0
        else
            fail "#$msg_num OUT sent but NOT in DB"
            FAILED=$((FAILED + 1))
            OUT_FAIL=$((OUT_FAIL + 1))
            return 1
        fi
    else
        fail "#$msg_num OUT send failed: $RESULT"
        FAILED=$((FAILED + 1))
        OUT_FAIL=$((OUT_FAIL + 1))
        return 1
    fi
}

# Pager → BPF-B (incoming via meshtastic CLI)
send_incoming() {
    local msg_num=$1
    local unique="IN_${msg_num}_$(date +%s%N | tail -c 8)"
    TOTAL=$((TOTAL + 1))

    arrow_in "#$msg_num Pager → BPF-B: $unique"

    # Send from pager to BPF-B via meshtastic CLI
    RESULT=$(meshtastic --host "$PAGER_IP" --sendtext "$unique" --dest "$DEVICE_NUM" 2>&1 || echo "CLI_ERROR")

    if echo "$RESULT" | grep -qi "error\|fail\|exception"; then
        # Some meshtastic versions return success even with warnings
        if echo "$RESULT" | grep -qi "Sending text"; then
            info "#$msg_num CLI warning but message queued"
        else
            fail "#$msg_num IN send failed: $(echo "$RESULT" | tail -1)"
            FAILED=$((FAILED + 1))
            IN_FAIL=$((IN_FAIL + 1))
            return 1
        fi
    fi

    # Wait for message to arrive via MQTT relay (cross-band, may take a few seconds)
    sleep 4

    # Check if message appeared in app DB
    MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$PAGER_NUM&limit=5" 2>/dev/null || echo '[]')
    if echo "$MSGS" | grep -q "$unique"; then
        pass "#$msg_num IN received and persisted in DB"
        PASSED=$((PASSED + 1))
        IN_OK=$((IN_OK + 1))
        return 0
    else
        # MQTT relay may be slower, try once more
        sleep 3
        MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$PAGER_NUM&limit=5" 2>/dev/null || echo '[]')
        if echo "$MSGS" | grep -q "$unique"; then
            pass "#$msg_num IN received (delayed) and persisted in DB"
            PASSED=$((PASSED + 1))
            IN_OK=$((IN_OK + 1))
            return 0
        else
            fail "#$msg_num IN NOT received in app (MQTT relay timeout?)"
            FAILED=$((FAILED + 1))
            IN_FAIL=$((IN_FAIL + 1))
            return 1
        fi
    fi
}

take_screenshot() {
    local name=$1
    curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/${name}.png" 2>/dev/null
    info "Screenshot: ${name}.png"
}

check_connection() {
    local s=$(curl -m 5 -s "$BASE/status" 2>/dev/null || echo '{}')
    local st=$(echo "$s" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")
    local sent=$(echo "$s" | python3 -c "import json,sys; print(json.load(sys.stdin).get('packetsSent',0))" 2>/dev/null || echo "?")
    local recv=$(echo "$s" | python3 -c "import json,sys; print(json.load(sys.stdin).get('packetsReceived',0))" 2>/dev/null || echo "?")
    info "Connection: status=$st, sent=$sent, recv=$recv"
    [ "$st" = "connected" ]
}

# ================================================================
# RUN 100 DMs IN 10 ROUNDS OF 10
# Each round: 5 outgoing (BPF-B → Pager) + 5 incoming (Pager → BPF-B)
# ================================================================

MSG=0
START_TIME=$(date +%s)

for ROUND in $(seq 1 10); do
    header "ROUND $ROUND/10 (messages $((MSG+1))-$((MSG+10)))"
    ROUND_START=$(date +%s)

    # 5 outgoing DMs
    for i in $(seq 1 5); do
        MSG=$((MSG + 1))
        send_outgoing $MSG || true
        sleep 1
    done

    # 5 incoming DMs
    for i in $(seq 1 5); do
        MSG=$((MSG + 1))
        send_incoming $MSG || true
        sleep 1
    done

    ROUND_END=$(date +%s)
    ROUND_DUR=$((ROUND_END - ROUND_START))

    # Screenshot every 2 rounds
    if [ $((ROUND % 2)) -eq 0 ]; then
        # Navigate to pager conversation to capture latest messages
        curl -m 5 -s -X POST "$BASE/action/navigate" \
            -H "Content-Type: application/json" \
            -d "{\"tab\":\"messages\",\"userNum\":$PAGER_NUM}" > /dev/null 2>&1
        sleep 1
        take_screenshot "round_${ROUND}_msg_${MSG}"
    fi

    # Connection check
    check_connection || {
        fail "ABORTING — connection lost after round $ROUND"
        break
    }

    echo "--- Round $ROUND done (${ROUND_DUR}s): $PASSED/$TOTAL passed | OUT=$OUT_OK/$((OUT_OK+OUT_FAIL)) IN=$IN_OK/$((IN_OK+IN_FAIL)) ---"
done

# Final screenshot
curl -m 5 -s -X POST "$BASE/action/navigate" \
    -H "Content-Type: application/json" \
    -d "{\"tab\":\"messages\",\"userNum\":$PAGER_NUM}" > /dev/null 2>&1
sleep 2
take_screenshot "final_msg_${MSG}"

END_TIME=$(date +%s)
TOTAL_DUR=$((END_TIME - START_TIME))

# Final status
echo ""
header "FINAL STATUS"
check_connection

echo ""
echo "================================================================"
echo "  BIDIRECTIONAL 100-DM STRESS TEST RESULTS"
echo "================================================================"
echo ""
echo "  Duration:     ${TOTAL_DUR}s"
echo "  Total:        $TOTAL messages"
echo "  Passed:       $PASSED"
echo "  Failed:       $FAILED"
echo ""
echo "  BPF-B → Pager (outgoing):  $OUT_OK passed, $OUT_FAIL failed"
echo "  Pager → BPF-B (incoming):  $IN_OK passed, $IN_FAIL failed"
echo ""
if [ $TOTAL -gt 0 ]; then
    echo "  Success rate:  $(( PASSED * 100 / TOTAL ))%"
fi
echo "  Screenshots:   $OUTDIR/"
echo "================================================================"
echo ""

echo "Screenshots captured:"
ls -la "$OUTDIR"/*.png 2>/dev/null || echo "  (none)"

exit $FAILED
