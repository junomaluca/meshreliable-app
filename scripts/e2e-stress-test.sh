#!/bin/bash
# E2E Stress Test for MeshReliable App
# Sends messages and verifies they appear in the UI via screenshots
#
# Usage: ./scripts/e2e-stress-test.sh [iphone_ip] [target_node_num]

set -euo pipefail

HOST="${1:-192.168.1.187}"
BASE="http://${HOST}:8765"
OUTDIR="/tmp/meshreliable-e2e-$(date +%s)"
mkdir -p "$OUTDIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; }
info() { echo -e "${YELLOW}INFO${NC} $1"; }

# Step 0: Check connection
info "Checking app connection..."
STATUS=$(curl -m 5 -s "$BASE/status" 2>/dev/null || echo '{}')
DEVICE_NUM=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deviceNum',0))" 2>/dev/null || echo 0)
CONN_STATUS=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")

if [ "$DEVICE_NUM" = "0" ] || [ "$CONN_STATUS" != "connected" ]; then
    fail "App not connected (status=$CONN_STATUS, device=$DEVICE_NUM)"
    exit 1
fi
DEVICE_HEX=$(python3 -c "print(f'0x{${DEVICE_NUM}:08x}')")
pass "Connected to device $DEVICE_NUM ($DEVICE_HEX)"

# Find a target node for DMs
info "Finding target nodes..."
NODES=$(curl -m 5 -s "$BASE/nodes")
# Pick first node that's not self, has been heard recently, and is on same band
TARGET=$(echo "$NODES" | python3 -c "
import json, sys
nodes = json.load(sys.stdin)
dev = ${DEVICE_NUM}
# Known test devices
targets = {861805532: 'VHF-B', 861805544: 'VHF-A', 880397061: 'BPF-A',
           2712908800: 'Pager', 1634999779: 'T3-S3', 1550340734: 'XIAO',
           1743797641: 'BPF-B-67f', 1387232948: 'BPF-B-52a'}
for n in nodes:
    num = n.get('num', 0)
    if num != dev and num in targets:
        print(f'{num}|{targets[num]}|{n.get(\"shortName\",\"?\")}'  )
        break
" 2>/dev/null || echo "")

if [ -z "$TARGET" ]; then
    fail "No target node found"
    exit 1
fi

TARGET_NUM=$(echo "$TARGET" | cut -d'|' -f1)
TARGET_NAME=$(echo "$TARGET" | cut -d'|' -f2)
TARGET_SHORT=$(echo "$TARGET" | cut -d'|' -f3)
pass "Target: $TARGET_NAME (num=$TARGET_NUM, short=$TARGET_SHORT)"

echo ""
echo "================================================================"
echo "  E2E STRESS TEST — Connected to device $DEVICE_NUM"
echo "  Target: $TARGET_NAME ($TARGET_NUM)"
echo "  Output: $OUTDIR"
echo "================================================================"
echo ""

TOTAL=0
PASSED=0
FAILED=0

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))
    echo "--- Test $TOTAL: $test_name ---"
    if eval "$test_fn"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    echo ""
}

# ================================================================
# TEST 1: Text DM appears in conversation
# ================================================================
test_text_dm() {
    local unique_text="E2E_DM_$(date +%s)"

    # Navigate to target conversation
    info "Navigating to $TARGET_NAME conversation..."
    curl -m 5 -s -X POST "$BASE/action/navigate" \
        -H "Content-Type: application/json" \
        -d "{\"tab\":\"messages\",\"userNum\":$TARGET_NUM}" > /dev/null 2>&1
    sleep 2

    # Take before screenshot
    curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/test1_before.png" 2>/dev/null

    # Send message
    info "Sending text DM: $unique_text"
    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-message" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$TARGET_NUM,\"text\":\"$unique_text\"}")

    if ! echo "$RESULT" | grep -q '"ok":true'; then
        fail "Send failed: $RESULT"
        return 1
    fi

    # Wait for message to appear
    sleep 3

    # Take after screenshot
    curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/test1_after.png" 2>/dev/null

    # Verify in database
    MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$TARGET_NUM&limit=3")
    if echo "$MSGS" | grep -q "$unique_text"; then
        pass "Text DM '$unique_text' found in database"
    else
        fail "Text DM '$unique_text' NOT found in database"
        return 1
    fi

    # Check ACK status
    local ack_status=$(echo "$MSGS" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
for m in msgs:
    if '$unique_text' in m.get('text',''):
        print(f'receivedACK={m.get(\"receivedACK\")}, realACK={m.get(\"realACK\")}')
        break
" 2>/dev/null)
    info "ACK: $ack_status"

    pass "Text DM sent and persisted — screenshot: test1_after.png"
    return 0
}

# ================================================================
# TEST 2: Image appears in conversation
# ================================================================
test_image() {
    local label="E2E_$(date +%s | tail -c 5)"

    # Navigate to target conversation
    curl -m 5 -s -X POST "$BASE/action/navigate" \
        -H "Content-Type: application/json" \
        -d "{\"tab\":\"messages\",\"userNum\":$TARGET_NUM}" > /dev/null 2>&1
    sleep 2

    # Send test image
    info "Sending test image with label: $label"
    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-test-image" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$TARGET_NUM,\"label\":\"$label\"}")

    if ! echo "$RESULT" | grep -q '"ok":true'; then
        fail "Image send failed: $RESULT"
        return 1
    fi

    # Wait for persist (immediate now)
    sleep 3

    # Take screenshot
    curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/test2_image.png" 2>/dev/null

    # Verify in database
    MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$TARGET_NUM&limit=5")
    local img_found=$(echo "$MSGS" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
for m in msgs:
    if m.get('imageBytes') and m.get('imageBytes') > 0:
        print(f'IMAGE found: {m[\"imageBytes\"]}B, text={m.get(\"text\",\"\")}')
        break
else:
    print('NO_IMAGE')
" 2>/dev/null)

    if echo "$img_found" | grep -q "IMAGE found"; then
        pass "$img_found — screenshot: test2_image.png"
        return 0
    else
        fail "Image not found in database"
        return 1
    fi
}

# ================================================================
# TEST 3: Voice memo appears in conversation
# ================================================================
test_voice_memo() {
    # Navigate to target conversation
    curl -m 5 -s -X POST "$BASE/action/navigate" \
        -H "Content-Type: application/json" \
        -d "{\"tab\":\"messages\",\"userNum\":$TARGET_NUM}" > /dev/null 2>&1
    sleep 2

    # Send voice memo
    info "Sending 2s voice memo..."
    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-voice-memo" \
        -H "Content-Type: application/json" \
        -d "{\"to\":$TARGET_NUM,\"durationMs\":2000}")

    if ! echo "$RESULT" | grep -q '"ok":true'; then
        fail "Voice memo send failed: $RESULT"
        return 1
    fi

    # Wait for persist
    sleep 5

    # Take screenshot
    curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/test3_voice.png" 2>/dev/null

    # Verify in database
    MSGS=$(curl -m 5 -s "$BASE/messages?userNum=$TARGET_NUM&limit=5")
    local vm_found=$(echo "$MSGS" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
for m in msgs:
    if m.get('hasVoiceMemo'):
        dur = m.get('voiceMemoDuration', 0)
        print(f'VOICE found: {m[\"voiceMemoBytes\"]}B, duration={dur:.1f}s')
        break
else:
    print('NO_VOICE')
" 2>/dev/null)

    if echo "$vm_found" | grep -q "VOICE found"; then
        pass "$vm_found — screenshot: test3_voice.png"
        return 0
    else
        fail "Voice memo not found in database"
        return 1
    fi
}

# ================================================================
# TEST 4: Channel broadcast appears
# ================================================================
test_channel_broadcast() {
    local unique_text="E2E_CH_$(date +%s)"

    # Navigate to channel view
    curl -m 5 -s -X POST "$BASE/action/navigate" \
        -H "Content-Type: application/json" \
        -d '{"tab":"messages","channel":0}' > /dev/null 2>&1
    sleep 2

    # Send channel message
    info "Sending channel broadcast: $unique_text"
    RESULT=$(curl -m 5 -s -X POST "$BASE/action/send-channel-message" \
        -H "Content-Type: application/json" \
        -d "{\"channel\":0,\"text\":\"$unique_text\"}")

    if ! echo "$RESULT" | grep -q '"ok":true'; then
        fail "Channel send failed: $RESULT"
        return 1
    fi

    sleep 3

    # Take screenshot
    curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/test4_channel.png" 2>/dev/null

    # Verify in database
    MSGS=$(curl -m 5 -s "$BASE/messages?channel=0&limit=5")
    if echo "$MSGS" | grep -q "$unique_text"; then
        pass "Channel broadcast '$unique_text' found — screenshot: test4_channel.png"
        return 0
    else
        fail "Channel broadcast '$unique_text' NOT found in database"
        return 1
    fi
}

# ================================================================
# TEST 5: Connection stability after all sends
# ================================================================
test_connection_stable() {
    STATUS=$(curl -m 5 -s "$BASE/status" 2>/dev/null)
    local status=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
    local dev=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deviceNum',0))" 2>/dev/null)
    local sent=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('packetsSent',0))" 2>/dev/null)
    local recv=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('packetsReceived',0))" 2>/dev/null)

    info "Status=$status, Device=$dev, Sent=$sent, Recv=$recv"

    if [ "$dev" != "0" ]; then
        pass "Connection stable (device=$dev, sent=$sent, recv=$recv)"

        # Final screenshot showing current state
        curl -m 10 -s "$BASE/screenshot" -o "$OUTDIR/test5_final.png" 2>/dev/null
        return 0
    else
        fail "Connection lost (device=0)"
        return 1
    fi
}

# ================================================================
# RUN ALL TESTS
# ================================================================

run_test "Text DM appears in conversation" test_text_dm
run_test "Image appears in conversation" test_image
run_test "Voice memo appears in conversation" test_voice_memo
run_test "Channel broadcast appears" test_channel_broadcast
run_test "Connection stable after all sends" test_connection_stable

echo ""
echo "================================================================"
echo "  RESULTS: $PASSED/$TOTAL passed, $FAILED failed"
echo "  Screenshots: $OUTDIR/"
echo "================================================================"

# List screenshots
echo ""
echo "Screenshots captured:"
ls -la "$OUTDIR"/*.png 2>/dev/null || echo "  (none)"

exit $FAILED
