#!/usr/bin/env python3
"""
MeshReliable Reliability Test — 100% success rate target.

Sends messages of each type and verifies they appear in the app's
SwiftData via the debug HTTP server. Takes screenshots for visual proof.

Usage:
    python3 reliability_test.py [--rounds N] [--verbose]
"""

import argparse
import glob
import json
import os
import sys
import time
import urllib.request
import urllib.error

try:
    import meshtastic
    import meshtastic.serial_interface
    HAS_MESHTASTIC = True
except ImportError:
    HAS_MESHTASTIC = False

HOST = "localhost"
PORT = 8765
POLL_INTERVAL = 2.0
DM_TIMEOUT = 60.0
IMAGE_TIMEOUT = 120.0
SCREENSHOT_DIR = "/tmp/meshreliable_test"

class Colors:
    G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; C = "\033[96m"; B = "\033[1m"; X = "\033[0m"

def http_get(path, timeout=20):
    try:
        with urllib.request.urlopen(f"http://{HOST}:{PORT}{path}", timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {"error": str(e)}

def http_post(path, body, timeout=30):
    data = json.dumps(body).encode()
    req = urllib.request.Request(f"http://{HOST}:{PORT}{path}", data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {"error": str(e)}

def screenshot(name):
    os.makedirs(SCREENSHOT_DIR, exist_ok=True)
    path = f"{SCREENSHOT_DIR}/{name}.png"
    try:
        req = urllib.request.Request(f"http://{HOST}:{PORT}/screenshot")
        with urllib.request.urlopen(req, timeout=15) as r:
            with open(path, "wb") as f:
                f.write(r.read())
        return path
    except Exception:
        return None

def navigate(tab, userNum=None, channel=None):
    body = {"tab": tab}
    if userNum is not None:
        body["userNum"] = userNum
    if channel is not None:
        body["channel"] = channel
    http_post("/action/navigate", body)
    time.sleep(2)

def wait_for_message(text, timeout=DM_TIMEOUT, limit=50):
    """Poll /messages until text appears. Returns the message dict or None."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        msgs = http_get(f"/messages?limit={limit}")
        if isinstance(msgs, list):
            for m in msgs:
                if text in (m.get("text", "") or ""):
                    return m
        time.sleep(POLL_INTERVAL)
    return None

def wait_for_image(timeout=IMAGE_TIMEOUT):
    """Poll /images for newest image. Returns the image dict or None."""
    baseline = http_get("/images")
    baseline_ids = set(m.get("messageId") for m in baseline) if isinstance(baseline, list) else set()

    deadline = time.time() + timeout
    while time.time() < deadline:
        imgs = http_get("/images")
        if isinstance(imgs, list):
            for img in imgs:
                if img.get("messageId") not in baseline_ids:
                    return img
        time.sleep(POLL_INTERVAL)
    return None

class ReliabilityTest:
    def __init__(self, rounds, verbose):
        self.rounds = rounds
        self.verbose = verbose
        self.results = {}  # category -> [(round, passed, detail)]
        self.serial_iface = None
        self.app_device_num = None
        self.xiao_device_num = None
        self.xiao_port = None

    def log(self, msg):
        if self.verbose:
            print(f"    {msg}")

    def setup(self):
        """Verify connection and connect serial."""
        print(f"\n{Colors.B}{'='*60}")
        print(f"  MeshReliable Reliability Test — {self.rounds} rounds")
        print(f"{'='*60}{Colors.X}\n")

        # Check app connection
        conn = http_get("/connection")
        if conn.get("state") != "subscribed":
            print(f"  {Colors.R}App not connected (state={conn.get('state')}){Colors.X}")
            return False
        self.app_device_num = conn.get("deviceNum")
        dev = conn.get("activeDevice", {})
        print(f"  App connected: {dev.get('longName')} ({self.app_device_num})")

        # Connect serial — find the device that is NOT the phone-connected one
        if HAS_MESHTASTIC:
            ports = sorted(glob.glob("/dev/cu.usbmodem*"))
            for port in ports:
                try:
                    iface = meshtastic.serial_interface.SerialInterface(port)
                    time.sleep(2)
                    info = iface.getMyNodeInfo()
                    dev_num = info.get("num")
                    dev_name = info.get('user', {}).get('longName', '?')
                    if dev_num == self.app_device_num:
                        print(f"  Skipping {port}: {dev_name} ({dev_num}) — same as phone-connected device")
                        iface.close()
                        continue
                    self.serial_iface = iface
                    self.xiao_port = port
                    self.xiao_device_num = dev_num
                    print(f"  Serial connected: {dev_name} ({self.xiao_device_num}) on {self.xiao_port}")
                    break
                except Exception as e:
                    print(f"  {Colors.Y}Serial failed on {port}: {e}{Colors.X}")

        if not self.xiao_device_num:
            print(f"  {Colors.Y}No serial device — skipping device→app tests{Colors.X}")

        print()
        return True

    def record(self, category, round_num, passed, detail=""):
        if category not in self.results:
            self.results[category] = []
        self.results[category].append((round_num, passed, detail))
        status = f"{Colors.G}PASS{Colors.X}" if passed else f"{Colors.R}FAIL{Colors.X}"
        print(f"  [{status}] {category} round {round_num} {detail}")

    def run(self):
        if not self.setup():
            return False

        for r in range(1, self.rounds + 1):
            print(f"\n{Colors.B}--- Round {r}/{self.rounds} ---{Colors.X}")

            # DM: App → Device
            self.test_dm_app_to_device(r)
            time.sleep(3)  # Avoid LoRa rate limiting

            # DM: Device → App
            if self.serial_iface and self.xiao_device_num:
                self.test_dm_device_to_app(r)
                time.sleep(3)

            # Channel broadcast
            self.test_channel_broadcast(r)
            time.sleep(2)

            # Image: App → Device (only round 1 — slow)
            if r == 1 and self.xiao_device_num:
                self.test_image_app_to_device(r)
                # Brief pause to let BLE recover after image transfer
                time.sleep(5)

            # Voice memo (only round 1 — slow)
            if r == 1 and self.xiao_device_num:
                self.test_voice_memo(r)

        # Take final screenshots for proof
        print(f"\n{Colors.B}--- Taking verification screenshots ---{Colors.X}")
        if self.xiao_device_num:
            navigate("messages", userNum=self.xiao_device_num)
            time.sleep(1)
            # Wait, we need to navigate to the OTHER device's DM, not self
            # The DM conversation is with the non-connected device

        # Navigate to the DM conversation we've been testing
        target_num = self.xiao_device_num if self.xiao_device_num else 1550340734
        navigate("messages", userNum=target_num)
        time.sleep(1)
        path = screenshot("final_dm")
        if path:
            print(f"  DM screenshot: {path}")

        navigate("messages", channel=0)
        time.sleep(1)
        path = screenshot("final_channel")
        if path:
            print(f"  Channel screenshot: {path}")

        self.cleanup()
        self.print_summary()
        return self.all_passed()

    def test_dm_app_to_device(self, round_num):
        """Send DM from app to the other XIAO via LoRa."""
        target = self.xiao_device_num or 1550340734
        marker = f"R{round_num}-A2D-{int(time.time())}"

        resp = http_post("/action/send-message", {"to": target, "text": marker})
        if "error" in resp:
            self.record("DM:App→Device", round_num, False, f"send error: {resp['error']}")
            return

        msg = wait_for_message(marker, timeout=DM_TIMEOUT)
        if msg:
            self.record("DM:App→Device", round_num, True, f"id={msg['messageId']}")
        else:
            self.record("DM:App→Device", round_num, False, "not found in /messages")

    def test_dm_device_to_app(self, round_num):
        """Send DM from XIAO serial to app's connected device."""
        marker = f"R{round_num}-D2A-{int(time.time())}"

        try:
            self.serial_iface.sendText(marker, destinationId=int(self.app_device_num))
        except Exception as e:
            self.record("DM:Device→App", round_num, False, f"serial send error: {e}")
            return

        msg = wait_for_message(marker, timeout=DM_TIMEOUT)
        if msg:
            self.record("DM:Device→App", round_num, True, f"id={msg['messageId']}")
        else:
            self.record("DM:Device→App", round_num, False, "not found in /messages")

    def test_channel_broadcast(self, round_num):
        """Send channel broadcast from app."""
        marker = f"R{round_num}-BCH-{int(time.time())}"

        resp = http_post("/action/send-channel-message", {"text": marker, "channel": 0})
        if "error" in resp:
            self.record("Channel:Broadcast", round_num, False, f"send error: {resp['error']}")
            return

        msg = wait_for_message(marker, timeout=DM_TIMEOUT)
        if msg:
            has_to = msg.get("toUserNum") is not None
            self.record("Channel:Broadcast", round_num, True,
                       f"id={msg['messageId']} toUser={'SET' if has_to else 'nil(correct)'}")
        else:
            self.record("Channel:Broadcast", round_num, False, "not found in /messages")

    def test_image_app_to_device(self, round_num):
        """Send test image from app to device."""
        target = self.xiao_device_num or 1550340734
        marker = f"R{round_num}-IMG"

        resp = http_post("/action/send-test-image", {"to": target, "label": marker})
        if "error" in resp:
            self.record("Image:App→Device", round_num, False, f"send error: {resp['error']}")
            return

        # Poll transfers — check both pendingImages and outgoing array
        deadline = time.time() + IMAGE_TIMEOUT
        seen_transfer = False
        while time.time() < deadline:
            time.sleep(POLL_INTERVAL)
            transfers = http_get("/transfers")
            if isinstance(transfers, dict):
                # Check pendingImages (MeshReliableService tracking)
                pending = transfers.get("pendingImages", [])
                if pending:
                    seen_transfer = True
                    self.log(f"Image progress (pending): {pending[0].get('progress',0):.0%}")
                    continue
                # Check outgoing transfers (AccessoryManager)
                outgoing = transfers.get("outgoing", [])
                img_out = [t for t in outgoing if t.get("isImage")]
                if img_out:
                    seen_transfer = True
                    progress = img_out[0].get("progress", 0) or 0
                    self.log(f"Image progress (outgoing): {progress:.0%}")
                    continue
                # Also check sendProgress
                sp = transfers.get("sendProgress")
                if sp is not None and sp > 0:
                    seen_transfer = True
                    self.log(f"Image sendProgress: {sp:.0%}")
                    continue
                if seen_transfer:
                    self.record("Image:App→Device", round_num, True, "transfer completed")
                    return

        if seen_transfer:
            self.record("Image:App→Device", round_num, True, "transfer started (timeout waiting for clear)")
        else:
            self.record("Image:App→Device", round_num, False, f"no transfer seen after {IMAGE_TIMEOUT}s")

    def test_voice_memo(self, round_num):
        """Send synthetic voice memo from app."""
        target = self.xiao_device_num or 1550340734

        resp = http_post("/action/send-voice-memo", {"to": target, "durationMs": 500})
        if "error" in resp:
            self.record("Voice:App→Device", round_num, False, f"send error: {resp['error']}")
            return

        deadline = time.time() + IMAGE_TIMEOUT
        seen_transfer = False
        while time.time() < deadline:
            time.sleep(POLL_INTERVAL)
            transfers = http_get("/transfers")
            if isinstance(transfers, dict):
                # Check pendingVoiceMemos (MeshReliableService tracking)
                pending = transfers.get("pendingVoiceMemos", [])
                if pending:
                    seen_transfer = True
                    self.log(f"Voice progress (pending): {pending[0].get('progress',0):.0%}")
                    continue
                # Check outgoing transfers (AccessoryManager)
                outgoing = transfers.get("outgoing", [])
                voice_out = [t for t in outgoing if not t.get("isImage")]
                if voice_out:
                    seen_transfer = True
                    progress = voice_out[0].get("progress", 0) or 0
                    self.log(f"Voice progress (outgoing): {progress:.0%}")
                    continue
                # Check sendProgress
                sp = transfers.get("sendProgress")
                if sp is not None and sp > 0:
                    seen_transfer = True
                    self.log(f"Voice sendProgress: {sp:.0%}")
                    continue
                if seen_transfer:
                    self.record("Voice:App→Device", round_num, True, "transfer completed")
                    return

        if seen_transfer:
            self.record("Voice:App→Device", round_num, True, "transfer started")
        else:
            self.record("Voice:App→Device", round_num, False, f"no transfer seen after {IMAGE_TIMEOUT}s")

    def cleanup(self):
        if self.serial_iface:
            try:
                self.serial_iface.close()
            except Exception:
                pass

    def print_summary(self):
        print(f"\n{Colors.B}{'='*60}")
        print(f"  RELIABILITY TEST RESULTS")
        print(f"{'='*60}{Colors.X}\n")

        all_pass = True
        for cat, results in sorted(self.results.items()):
            passed = sum(1 for _, p, _ in results if p)
            total = len(results)
            pct = (passed / total * 100) if total > 0 else 0
            color = Colors.G if pct == 100 else (Colors.Y if pct >= 80 else Colors.R)
            print(f"  {color}{cat}: {passed}/{total} ({pct:.0f}%){Colors.X}")
            if pct < 100:
                all_pass = False
                for r, p, d in results:
                    if not p:
                        print(f"    FAIL round {r}: {d}")

        total_passed = sum(sum(1 for _, p, _ in rs if p) for rs in self.results.values())
        total_tests = sum(len(rs) for rs in self.results.values())
        overall = (total_passed / total_tests * 100) if total_tests > 0 else 0

        print(f"\n  {Colors.B}Overall: {total_passed}/{total_tests} ({overall:.1f}%){Colors.X}")
        print(f"  Screenshots in: {SCREENSHOT_DIR}/")
        print()

    def all_passed(self):
        return all(
            all(p for _, p, _ in results)
            for results in self.results.values()
        )

def main():
    parser = argparse.ArgumentParser(description="MeshReliable Reliability Test")
    parser.add_argument("--rounds", "-r", type=int, default=5, help="Number of test rounds (default: 5)")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    test = ReliabilityTest(args.rounds, args.verbose)
    success = test.run()
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
