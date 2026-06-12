#!/bin/bash
# E2E 100-Message Stress Test for MeshReliable App
# Sends 100 messages (text/image/voice/channel mix) and verifies each in DB + periodic screenshots
#
# Usage: ./scripts/e2e-stress-100.sh [iphone_ip]

set -euo pipefail

HOST="${1:-192.168.1.187}"
BASE="http://${HOST}:8765"
OUTDIR="/tmp/meshreliable-stress100-$(date +%s)"
mkdir -p "$OUTDIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; }
info() { echo -e "${YELLOW}INFO${NC} $1"; }
header() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# Step 0: Check connection
info "Checking app connection..."
STATUS=$(curl -m 5 -s "$BASE/status" 2>/dev/null || echo '{}')
DEVICE_NUM=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deviceNum',0))" 2>/dev/null || echo 0)
CONN_STATUS=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")

if [ "$DEVICE_NUM" = "0" ] || [ "$CONN_STATUS" != "connected" ]; then
    fail "App not connected (status=$CONN_STATUS, device=$DEVICE_NUM)"
    exit 1
fi
pass "Connected to device $DEVICE_NUM"

# Find target nodes (pick up to 3 different targets for variety)
info "Finding target nodes..."
NODES=$(curl -m 5 -s "$BASE/nodes")
TARGETS=$(echo "$NODES" | python3 -c "
import json, sys
nodes = json.load(sys.stdin)
dev = ${DEVICE_NUM}
known = {861805532: 'VHF-B', 861805544: 'VHF-A', 880397061: 'BPF-A',
         2712908800: 'Pager', 1634999779: 'T3-S3', 1550340734: 'XIAO',
         1743797641: 'BPF-B-67f', 1387232948: 'BPF-B-52a', 651925989: 'BPF-B-26d',
         1290173665: 'BPF-B-4ce'}
found = []
for n in nodes:
    num = n.get('num', 0)
    if num != dev and num in known:
        found.append(f'{num}|{known[num]}')
        if len(found) >= 3:
            break
for f in found:
    print(f)
" 2>/dev/null || echo "")

if [ -z "$TARGETS" ]; then
    fail "No target nodes found"
    exit 1
fi

# Parse first target as primary
PRIMARY_NUM=$(echo "$TARGETS" | head -1 | cut -d'|' -f1)
PRIMARY_NAME=$(echo "$TARGETS" | head -1 | cut -d'|' -f2)
TARGET_COUNT=$(echo "$TARGETS" | wc -l | tr -d ' ')

# Build target arrays
declare -a T_NUMS T_NAMES
i=0
while IFS='|' read -r num name; do
    T_NUMS[$i]=$num
    T_NAMES[$i]=$name
    i=$((i + 1))
done <<< "$TARGETS"

pass "Found $TARGET_COUNT target(s): $(echo "$TARGETS" | tr '\n' ', ')"

echo ""
echo "================================================================"
echo "  100-MESSAGE STRESS TEST"
echo "  Device: $DEVICE_NUM"
echo "  Primary target: $PRIMARY_NAME ($PRIMARY_NUM)"
echo "  Output: $OUTDIR"
echo "================================================================"
echo ""

TOTAL=0
PASSED=0
FAILED=0
TEXT_OK=0; TEXT_FAIL=0
IMG_OK=0; IMG_FAIL=0
VOICE_OK=0; VOICE_FAIL=0
CHAN_OK=0; CHAN_FAIL=0

# Navigate to primary target conversation
info "Navigating to $PRIMARY_NAME conversation..."
curl -m 5 -s -X POST "$BASE/action/navigate" \
    -H "Content-Type: application/json" \
    -d "{\"tab\":\"messages\",\"userNum\":$PRIMARY_NUM}" > /dev/null 2>&1
sleep 2

# Take initial screenshot
curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/00_initial.png" 2>/dev/null
info "Initial screenshot saved"

# ================================================================
# MESSAGE SCHEDULE:
#   Messages 1-70:  Text DMs (to rotating targets)
#   Messages 71-85: Images (to primary target)
#   Messages 86-95: Voice memos (to primary target)
#   Messages 96-100: Channel broadcasts
#
# Interleaved: send in rounds of 10 (7 text, 1-2 image, 1 voice/channel)
# ================================================================

send_text() {
    local msg_num=$1
    local target_num=$2
    local target_name=$3
    local unique="STRESS_${msg_num}_$(date +%s)"

    TOTAL=$((TOTAL + 1))

    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-message" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$target_num,\"text\":\"$unique\"}" 2>/dev/null || echo '{"error":"timeout"}')

    if echo "$RESULT" | grep -q '"ok":true'; then
        # Verify in DB
        sleep 1
        MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$target_num&limit=3" 2>/dev/null || echo '[]')
        if echo "$MSGS" | grep -q "$unique"; then
            pass "#$msg_num TEXT→$target_name: $unique"
            PASSED=$((PASSED + 1))
            TEXT_OK=$((TEXT_OK + 1))
            return 0
        else
            fail "#$msg_num TEXT→$target_name: sent OK but not in DB"
            FAILED=$((FAILED + 1))
            TEXT_FAIL=$((TEXT_FAIL + 1))
            return 1
        fi
    else
        fail "#$msg_num TEXT→$target_name: send failed ($RESULT)"
        FAILED=$((FAILED + 1))
        TEXT_FAIL=$((TEXT_FAIL + 1))
        return 1
    fi
}

send_image() {
    local msg_num=$1
    local target_num=$2
    local target_name=$3
    local label="S${msg_num}"

    TOTAL=$((TOTAL + 1))

    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-test-image" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$target_num,\"label\":\"$label\"}" 2>/dev/null || echo '{"error":"timeout"}')

    if echo "$RESULT" | grep -q '"ok":true'; then
        sleep 1
        MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$target_num&limit=5" 2>/dev/null || echo '[]')
        local img_check=$(echo "$MSGS" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
for m in msgs:
    if m.get('imageBytes') and m.get('imageBytes') > 0:
        print('OK')
        break
else:
    print('NONE')
" 2>/dev/null || echo "NONE")

        if [ "$img_check" = "OK" ]; then
            pass "#$msg_num IMAGE→$target_name: $label"
            PASSED=$((PASSED + 1))
            IMG_OK=$((IMG_OK + 1))
            return 0
        else
            fail "#$msg_num IMAGE→$target_name: sent OK but no image in DB"
            FAILED=$((FAILED + 1))
            IMG_FAIL=$((IMG_FAIL + 1))
            return 1
        fi
    else
        fail "#$msg_num IMAGE→$target_name: send failed ($RESULT)"
        FAILED=$((FAILED + 1))
        IMG_FAIL=$((IMG_FAIL + 1))
        return 1
    fi
}

send_voice() {
    local msg_num=$1
    local target_num=$2
    local target_name=$3
    local dur=$((1000 + (msg_num % 3) * 1000))  # 1-3 seconds

    TOTAL=$((TOTAL + 1))

    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-voice-memo" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$target_num,\"durationMs\":$dur}" 2>/dev/null || echo '{"error":"timeout"}')

    if echo "$RESULT" | grep -q '"ok":true'; then
        sleep 2
        MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$target_num&limit=5" 2>/dev/null || echo '[]')
        local vm_check=$(echo "$MSGS" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
for m in msgs:
    if m.get('hasVoiceMemo'):
        print('OK')
        break
else:
    print('NONE')
" 2>/dev/null || echo "NONE")

        if [ "$vm_check" = "OK" ]; then
            pass "#$msg_num VOICE→$target_name: ${dur}ms"
            PASSED=$((PASSED + 1))
            VOICE_OK=$((VOICE_OK + 1))
            return 0
        else
            fail "#$msg_num VOICE→$target_name: sent OK but no voice in DB"
            FAILED=$((FAILED + 1))
            VOICE_FAIL=$((VOICE_FAIL + 1))
            return 1
        fi
    else
        fail "#$msg_num VOICE→$target_name: send failed ($RESULT)"
        FAILED=$((FAILED + 1))
        VOICE_FAIL=$((VOICE_FAIL + 1))
        return 1
    fi
}

send_channel() {
    local msg_num=$1
    local unique="STRESS_CH_${msg_num}_$(date +%s)"

    TOTAL=$((TOTAL + 1))

    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-channel-message" \
        -H "Content-Type: application/json" \
        -d "{\"channel\":0,\"text\":\"$unique\"}" 2>/dev/null || echo '{"error":"timeout"}')

    if echo "$RESULT" | grep -q '"ok":true'; then
        sleep 1
        MSGS=$(curl -m 5 -s "$BASE/messages?channel=0&limit=5" 2>/dev/null || echo '[]')
        if echo "$MSGS" | grep -q "$unique"; then
            pass "#$msg_num CHANNEL: $unique"
            PASSED=$((PASSED + 1))
            CHAN_OK=$((CHAN_OK + 1))
            return 0
        else
            fail "#$msg_num CHANNEL: sent OK but not in DB"
            FAILED=$((FAILED + 1))
            CHAN_FAIL=$((CHAN_FAIL + 1))
            return 1
        fi
    else
        fail "#$msg_num CHANNEL: send failed ($RESULT)"
        FAILED=$((FAILED + 1))
        CHAN_FAIL=$((CHAN_FAIL + 1))
        return 1
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
    if [ "$st" != "connected" ]; then
        fail "CONNECTION LOST at message $TOTAL!"
        return 1
    fi
    return 0
}

# ================================================================
# RUN 100 MESSAGES IN 10 ROUNDS OF 10
# ================================================================

MSG=0
for ROUND in $(seq 1 10); do
    header "ROUND $ROUND/10 (messages $((MSG+1))-$((MSG+10)))"

    # Pick target for this round (rotate through available targets)
    T_IDX=$(( (ROUND - 1) % TARGET_COUNT ))
    ROUND_TARGET=${T_NUMS[$T_IDX]}
    ROUND_NAME=${T_NAMES[$T_IDX]}

    # Navigate to this target's conversation
    curl -m 5 -s -X POST "$BASE/action/navigate" \
        -H "Content-Type: application/json" \
        -d "{\"tab\":\"messages\",\"userNum\":$ROUND_TARGET}" > /dev/null 2>&1
    sleep 1

    # Send 7 text messages
    for i in $(seq 1 7); do
        MSG=$((MSG + 1))
        send_text $MSG $ROUND_TARGET "$ROUND_NAME" || true
        sleep 1
    done

    # Send 1 image
    MSG=$((MSG + 1))
    send_image $MSG $ROUND_TARGET "$ROUND_NAME" || true
    sleep 2

    # Send 1 voice memo (rounds 1-5) or 1 channel broadcast (rounds 6-10)
    MSG=$((MSG + 1))
    if [ $ROUND -le 5 ]; then
        send_voice $MSG $ROUND_TARGET "$ROUND_NAME" || true
    else
        # Navigate to channel for broadcast
        curl -m 5 -s -X POST "$BASE/action/navigate" \
            -H "Content-Type: application/json" \
            -d '{"tab":"messages","channel":0}' > /dev/null 2>&1
        sleep 1
        send_channel $MSG || true
    fi
    sleep 2

    # Send 1 more text to round out to 10
    MSG=$((MSG + 1))
    # Navigate back to DM for text
    if [ $ROUND -gt 5 ]; then
        curl -m 5 -s -X POST "$BASE/action/navigate" \
            -H "Content-Type: application/json" \
            -d "{\"tab\":\"messages\",\"userNum\":$ROUND_TARGET}" > /dev/null 2>&1
        sleep 1
    fi
    send_text $MSG $ROUND_TARGET "$ROUND_NAME" || true
    sleep 1

    # Screenshot every 2 rounds
    if [ $((ROUND % 2)) -eq 0 ]; then
        take_screenshot "round_${ROUND}_msg_${MSG}"
    fi

    # Connection check every round
    check_connection || {
        fail "ABORTING — connection lost after round $ROUND"
        break
    }

    echo "--- Round $ROUND complete: $PASSED/$TOTAL passed so far ---"
done

# Final screenshot
take_screenshot "final_msg_${MSG}"

# Final connection check
echo ""
header "FINAL STATUS"
check_connection

echo ""
echo "================================================================"
echo "  100-MESSAGE STRESS TEST RESULTS"
echo "================================================================"
echo ""
echo "  Total:    $TOTAL messages"
echo "  Passed:   $PASSED"
echo "  Failed:   $FAILED"
echo ""
echo "  Text DMs:     $TEXT_OK passed, $TEXT_FAIL failed"
echo "  Images:       $IMG_OK passed, $IMG_FAIL failed"
echo "  Voice Memos:  $VOICE_OK passed, $VOICE_FAIL failed"
echo "  Channel:      $CHAN_OK passed, $CHAN_FAIL failed"
echo ""
echo "  Screenshots:  $OUTDIR/"
echo "================================================================"
echo ""

# List screenshots
echo "Screenshots captured:"
ls -la "$OUTDIR"/*.png 2>/dev/null || echo "  (none)"

if [ $FAILED -gt 0 ]; then
    echo ""
    echo "FAILURE RATE: $FAILED/$TOTAL ($(( FAILED * 100 / TOTAL ))%)"
fi

exit $FAILED
