#!/bin/bash
# 100-Message Mixed DM Stress Test
# Sends 100 DMs (text/image/voice mix) to a target node
# Verifies each in DB + periodic UI screenshots
#
# Usage: ./scripts/e2e-mixed-100.sh [iphone_ip] [target_node_num]

set -euo pipefail

HOST="${1:-192.168.1.187}"
BASE="http://${HOST}:8765"
OUTDIR="/tmp/meshreliable-mixed100-$(date +%s)"
mkdir -p "$OUTDIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; }
info() { echo -e "${YELLOW}INFO${NC} $1"; }
header() { echo -e "\n${CYAN}======== $1 ========${NC}"; }

# Pre-flight
info "Checking app connection..."
STATUS=$(curl -m 5 -s "$BASE/status" 2>/dev/null || echo '{}')
DEVICE_NUM=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deviceNum',0))" 2>/dev/null || echo 0)
CONN_STATUS=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")

if [ "$DEVICE_NUM" = "0" ] || [ "$CONN_STATUS" != "connected" ]; then
    fail "App not connected (status=$CONN_STATUS, device=$DEVICE_NUM)"
    exit 1
fi
pass "Connected to device $DEVICE_NUM"

# Find target — prefer pager, fall back to first known node
info "Finding target node..."
NODES=$(curl -m 5 -s "$BASE/nodes")
TARGET_NUM="${2:-}"
TARGET_NAME=""

if [ -z "$TARGET_NUM" ]; then
    TARGET=$(echo "$NODES" | python3 -c "
import json, sys
nodes = json.load(sys.stdin)
dev = ${DEVICE_NUM}
known = {861805532: 'VHF-B', 861805544: 'VHF-A', 880397061: 'BPF-A',
         2712908800: 'Pager', 1634999779: 'T3-S3', 1550340734: 'XIAO',
         1743797641: 'BPF-B-67f', 1387232948: 'BPF-B-52a', 651925989: 'BPF-B-26d',
         1290173665: 'BPF-B-4ce'}
# Prefer pager
for n in nodes:
    num = n.get('num', 0)
    if num == 2712908800 and num != dev:
        print(f'{num}|Pager')
        sys.exit()
# Otherwise first known
for n in nodes:
    num = n.get('num', 0)
    if num != dev and num in known:
        print(f'{num}|{known[num]}')
        sys.exit()
" 2>/dev/null || echo "")
    TARGET_NUM=$(echo "$TARGET" | cut -d'|' -f1)
    TARGET_NAME=$(echo "$TARGET" | cut -d'|' -f2)
else
    TARGET_NAME="Node-$TARGET_NUM"
fi

if [ -z "$TARGET_NUM" ]; then
    fail "No target node found"
    exit 1
fi
pass "Target: $TARGET_NAME ($TARGET_NUM)"

echo ""
echo "================================================================"
echo "  100-MESSAGE MIXED DM STRESS TEST"
echo "  From: Device $DEVICE_NUM"
echo "  To:   $TARGET_NAME ($TARGET_NUM)"
echo "  Mix:  70 text + 15 images + 15 voice memos"
echo "  Output: $OUTDIR"
echo "================================================================"
echo ""

# Navigate to target conversation
info "Navigating to $TARGET_NAME conversation..."
curl -m 5 -s -X POST "$BASE/action/navigate" \
    -H "Content-Type: application/json" \
    -d "{\"tab\":\"messages\",\"userNum\":$TARGET_NUM}" > /dev/null 2>&1
sleep 2
curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/00_initial.png" 2>/dev/null

TOTAL=0; PASSED=0; FAILED=0
TEXT_OK=0; TEXT_FAIL=0
IMG_OK=0; IMG_FAIL=0
VOICE_OK=0; VOICE_FAIL=0

send_text() {
    local msg_num=$1
    local unique="M${msg_num}_$(date +%s%N | tail -c 6)"
    TOTAL=$((TOTAL + 1))

    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-message" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$TARGET_NUM,\"text\":\"$unique\"}" 2>/dev/null || echo '{"error":"timeout"}')

    if echo "$RESULT" | grep -q '"ok":true'; then
        sleep 1
        MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$TARGET_NUM&limit=3" 2>/dev/null || echo '[]')
        if echo "$MSGS" | grep -q "$unique"; then
            pass "#$msg_num TEXT: $unique"
            PASSED=$((PASSED + 1)); TEXT_OK=$((TEXT_OK + 1))
            return 0
        else
            fail "#$msg_num TEXT: sent but not in DB"
            FAILED=$((FAILED + 1)); TEXT_FAIL=$((TEXT_FAIL + 1))
            return 1
        fi
    else
        fail "#$msg_num TEXT: send failed"
        FAILED=$((FAILED + 1)); TEXT_FAIL=$((TEXT_FAIL + 1))
        return 1
    fi
}

send_image() {
    local msg_num=$1
    local label="I${msg_num}"
    TOTAL=$((TOTAL + 1))

    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-test-image" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$TARGET_NUM,\"label\":\"$label\"}" 2>/dev/null || echo '{"error":"timeout"}')

    if echo "$RESULT" | grep -q '"ok":true'; then
        sleep 2
        MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$TARGET_NUM&limit=5" 2>/dev/null || echo '[]')
        local check=$(echo "$MSGS" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
for m in msgs:
    if m.get('imageBytes',0) > 0:
        print('OK')
        break
else:
    print('NO')
" 2>/dev/null || echo "NO")
        if [ "$check" = "OK" ]; then
            pass "#$msg_num IMAGE: $label"
            PASSED=$((PASSED + 1)); IMG_OK=$((IMG_OK + 1))
            return 0
        else
            fail "#$msg_num IMAGE: sent but not in DB"
            FAILED=$((FAILED + 1)); IMG_FAIL=$((IMG_FAIL + 1))
            return 1
        fi
    else
        fail "#$msg_num IMAGE: send failed"
        FAILED=$((FAILED + 1)); IMG_FAIL=$((IMG_FAIL + 1))
        return 1
    fi
}

send_voice() {
    local msg_num=$1
    local dur=$((1000 + (msg_num % 4) * 1000))
    TOTAL=$((TOTAL + 1))

    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-voice-memo" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$TARGET_NUM,\"durationMs\":$dur}" 2>/dev/null || echo '{"error":"timeout"}')

    if echo "$RESULT" | grep -q '"ok":true'; then
        sleep 2
        MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$TARGET_NUM&limit=5" 2>/dev/null || echo '[]')
        local check=$(echo "$MSGS" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
for m in msgs:
    if m.get('hasVoiceMemo'):
        print('OK')
        break
else:
    print('NO')
" 2>/dev/null || echo "NO")
        if [ "$check" = "OK" ]; then
            pass "#$msg_num VOICE: ${dur}ms"
            PASSED=$((PASSED + 1)); VOICE_OK=$((VOICE_OK + 1))
            return 0
        else
            fail "#$msg_num VOICE: sent but not in DB"
            FAILED=$((FAILED + 1)); VOICE_FAIL=$((VOICE_FAIL + 1))
            return 1
        fi
    else
        fail "#$msg_num VOICE: send failed"
        FAILED=$((FAILED + 1)); VOICE_FAIL=$((VOICE_FAIL + 1))
        return 1
    fi
}

take_screenshot() {
    local name=$1
    # Navigate to conversation to show latest messages
    curl -m 5 -s -X POST "$BASE/action/navigate" \
        -H "Content-Type: application/json" \
        -d "{\"tab\":\"messages\",\"userNum\":$TARGET_NUM}" > /dev/null 2>&1
    sleep 1
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
# MESSAGE SCHEDULE (100 messages in 10 rounds of 10)
# Each round: 7 text + 1-2 images + 1-2 voice memos = 10
#
# Rounds 1-5:  7 text + 2 images + 1 voice  = 10 × 5 = 50
# Rounds 6-10: 7 text + 1 image  + 2 voice  = 10 × 5 = 50
# Total: 70 text + 15 images + 15 voice = 100
# ================================================================

MSG=0
START_TIME=$(date +%s)

for ROUND in $(seq 1 10); do
    header "ROUND $ROUND/10 (messages $((MSG+1))-$((MSG+10)))"
    ROUND_START=$(date +%s)

    # 7 text messages (3s between for BLE stability)
    for i in $(seq 1 7); do
        MSG=$((MSG + 1))
        send_text $MSG || true
        sleep 3
    done

    if [ $ROUND -le 5 ]; then
        # 2 images + 1 voice (5s between media for BLE stability)
        MSG=$((MSG + 1)); send_image $MSG || true; sleep 5
        MSG=$((MSG + 1)); send_image $MSG || true; sleep 5
        MSG=$((MSG + 1)); send_voice $MSG || true; sleep 5
    else
        # 1 image + 2 voice
        MSG=$((MSG + 1)); send_image $MSG || true; sleep 5
        MSG=$((MSG + 1)); send_voice $MSG || true; sleep 5
        MSG=$((MSG + 1)); send_voice $MSG || true; sleep 5
    fi

    ROUND_END=$(date +%s)
    ROUND_DUR=$((ROUND_END - ROUND_START))

    # Screenshot every 2 rounds
    if [ $((ROUND % 2)) -eq 0 ]; then
        take_screenshot "round_${ROUND}_msg_${MSG}"
    fi

    # Connection check
    check_connection || {
        fail "CONNECTION LOST after round $ROUND"
        break
    }

    echo "--- Round $ROUND (${ROUND_DUR}s): $PASSED/$TOTAL passed | T=$TEXT_OK I=$IMG_OK V=$VOICE_OK ---"
done

# Final screenshot
take_screenshot "final_msg_${MSG}"

END_TIME=$(date +%s)
TOTAL_DUR=$((END_TIME - START_TIME))

header "FINAL STATUS"
check_connection

echo ""
echo "================================================================"
echo "  100-MESSAGE MIXED DM STRESS TEST — RESULTS"
echo "================================================================"
echo ""
echo "  Duration:     ${TOTAL_DUR}s"
echo "  Total:        $TOTAL messages"
echo "  Passed:       $PASSED"
echo "  Failed:       $FAILED"
echo ""
echo "  Text DMs:     $TEXT_OK ok / $TEXT_FAIL fail  (target: 70)"
echo "  Images:       $IMG_OK ok / $IMG_FAIL fail  (target: 15)"
echo "  Voice Memos:  $VOICE_OK ok / $VOICE_FAIL fail  (target: 15)"
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
