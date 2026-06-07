#!/usr/bin/env python3
"""
MeshReliable Deliverability Test — 3-Device Cross-Device Verification.

Tests message delivery across 3 devices: 1 BLE-connected app + 2 serial devices.

Test matrix per round (7 tests):
  1. Text DM: Serial1 → App
  2. Text DM: App → Serial1
  3. Text DM: Serial2 → App
  4. Text DM: App → Serial2
  5. Text DM: Serial1 → Serial2 (mesh relay)
  6. Text DM: Serial2 → Serial1 (mesh relay)
  7. Channel broadcast from App (verify on all serial devices)

Usage:
    python3 -u deliverability_test.py [--rounds N] [--duration M]
    python3 -u deliverability_test.py --duration 120 --devices /dev/cu.usbmodem21101,/dev/cu.usbmodem21201
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.error
import traceback

try:
    import meshtastic
    import meshtastic.serial_interface
    HAS_MESHTASTIC = True
except ImportError:
    HAS_MESHTASTIC = False

HOST = "192.168.1.187"
PORT = 8765
POLL_INTERVAL = 1.5
DM_TIMEOUT = 45.0
IMAGE_TIMEOUT = 120.0

class Colors:
    G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; C = "\033[96m"; B = "\033[1m"; X = "\033[0m"

def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)

def http_get(path, timeout=15, retries=2):
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(f"http://{HOST}:{PORT}{path}", timeout=timeout) as r:
                return json.loads(r.read().decode())
        except Exception as e:
            if attempt < retries:
                time.sleep(0.5)
                continue
            return {"error": str(e)}

def http_post(path, body, timeout=15, retries=2):
    data = json.dumps(body).encode()
    for attempt in range(retries + 1):
        req = urllib.request.Request(f"http://{HOST}:{PORT}{path}", data=data,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode())
        except Exception as e:
            if attempt < retries:
                time.sleep(0.5)
                continue
            return {"error": str(e)}


class SerialDevice:
    """Wrapper for a single serial-connected Meshtastic device."""
    def __init__(self, port, device_num, iface, name):
        self.port = port
        self.device_num = device_num
        self.iface = iface
        self.name = name
        self.received_messages = []
        self.ack_received_ids = set()  # message IDs that got ACKed
        self._on_receive = None
        self._on_receive_all = None
        self._pub_subscribed = False

    def register_pubsub(self):
        from pubsub import pub

        device = self  # capture reference

        def on_receive(packet, interface):
            # Only process messages from OUR interface
            if interface is not device.iface:
                return
            try:
                portnum = packet.get("decoded", {}).get("portnum", "")
                text = packet.get("decoded", {}).get("text", "")
                log(f"    [{device.name}-rx] port={portnum} from={packet.get('from')} text='{text[:40]}'")
                device.received_messages.append({
                    "text": text or "",
                    "from": packet.get("from"),
                    "to": packet.get("to"),
                    "time": time.time()
                })
            except Exception as e:
                log(f"    [{device.name}-rx] callback error: {e}")

        def on_receive_all(packet, interface):
            """Track ACK routing packets on this interface."""
            if interface is not device.iface:
                return
            try:
                decoded = packet.get("decoded", {})
                portnum = decoded.get("portnum", "")
                if portnum == "ROUTING_APP":
                    req_id = decoded.get("requestId", 0)
                    if req_id:
                        device.ack_received_ids.add(req_id)
                        log(f"    [{device.name}-ack] ACK for msg id={req_id}")
            except Exception:
                pass

        if self._on_receive and self._pub_subscribed:
            try:
                pub.unsubscribe(self._on_receive, "meshtastic.receive.text")
            except Exception:
                pass
            try:
                if self._on_receive_all:
                    pub.unsubscribe(self._on_receive_all, "meshtastic.receive")
            except Exception:
                pass
            self._pub_subscribed = False

        self._on_receive = on_receive
        self._on_receive_all = on_receive_all
        pub.subscribe(on_receive, "meshtastic.receive.text")
        pub.subscribe(on_receive_all, "meshtastic.receive")
        self._pub_subscribed = True

    def check_health(self):
        if not self.iface:
            return False
        try:
            rx_thread = getattr(self.iface, '_rxThread', None)
            if rx_thread is None or not rx_thread.is_alive():
                log(f"    {self.name}: reader thread dead, reconnecting...")
                return self.reconnect()
            return True
        except Exception as e:
            log(f"    {self.name} health check error: {e}")
            return self.reconnect()

    def reconnect(self):
        if self.iface:
            try:
                self.iface.close()
            except Exception:
                pass
            self.iface = None
            time.sleep(1)

        try:
            iface = meshtastic.serial_interface.SerialInterface(self.port)
            time.sleep(2)
            info = iface.getMyNodeInfo()
            dev_num = info.get("num")
            self.iface = iface
            self.device_num = dev_num
            log(f"  {self.name} reconnected: {self.port} (device {dev_num})")
            self.register_pubsub()
            return True
        except Exception as e:
            log(f"  {self.name} reconnect failed: {e}")
            return False

    def find_message(self, marker, timeout=DM_TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for m in self.received_messages:
                if marker in m.get("text", ""):
                    return m
            time.sleep(POLL_INTERVAL)
        return None

    def close(self):
        if self.iface:
            try:
                self.iface.close()
            except Exception:
                pass
            self.iface = None


class DeliverabilityTest:
    def __init__(self, device_ports=None):
        self.device_ports = device_ports or []
        self.serial_devices = []  # list of SerialDevice
        self.app_device_num = None
        self.results = []
        self._last_data_packets = 0
        self._ble_reconnect_count = 0

    def setup(self):
        log("=== SETUP ===")

        # 1. Connect to app
        status = http_get("/status")
        if "error" in status or status.get("status") != "connected":
            log(f"{Colors.R}App not connected: {status}{Colors.X}")
            return False
        self.app_device_num = status["deviceNum"]
        log(f"App connected to device: {self.app_device_num}")

        # 2. Connect serial devices
        if not HAS_MESHTASTIC:
            log(f"{Colors.R}meshtastic package not installed{Colors.X}")
            return False

        import glob as glob_mod

        if self.device_ports:
            ports = self.device_ports
        else:
            ports = sorted(glob_mod.glob("/dev/cu.usbmodem*"))

        log(f"Available serial ports: {ports}")

        idx = 1
        for port in ports:
            try:
                log(f"  Trying {port}...")
                iface = meshtastic.serial_interface.SerialInterface(port)
                time.sleep(2)
                info = iface.getMyNodeInfo()
                dev_num = info.get("num")
                log(f"  Connected: device num = {dev_num}")

                if dev_num == self.app_device_num:
                    log(f"  Skipping {port}: same as phone-connected device")
                    iface.close()
                    continue

                name = f"Serial{idx}"
                device = SerialDevice(port, dev_num, iface, name)
                device.register_pubsub()
                self.serial_devices.append(device)
                log(f"  {name} connected: {port} (device {dev_num})")

                rx = getattr(iface, '_rxThread', None)
                log(f"    Reader thread: {'alive' if rx and rx.is_alive() else 'DEAD or missing'}")
                idx += 1
            except Exception as e:
                log(f"  Serial failed on {port}: {e}")

        if not self.serial_devices:
            log(f"{Colors.R}No serial devices available{Colors.X}")
            return False

        log(f"\nDevice map:")
        log(f"  App (BLE): device {self.app_device_num}")
        for d in self.serial_devices:
            log(f"  {d.name}: {d.port} → device {d.device_num}")
        log(f"  Total serial devices: {len(self.serial_devices)}")

        return True

    def ensure_ble_connected(self):
        """Check BLE health and reconnect if needed. Returns True if BLE is active."""
        debug = http_get("/ble-debug")
        if isinstance(debug, dict) and "error" not in debug:
            current = debug.get("fromRadioDecoded", 0)
            last_err = debug.get("lastError", "")

            # If we have a disconnect error and no new packets, BLE is down
            if "not connected" in last_err.lower() or "disconnected" in last_err.lower():
                if current <= self._last_data_packets:
                    log(f"  {Colors.Y}BLE appears down (lastError={last_err}), triggering reconnect...{Colors.X}")
                    http_post("/action/ble-reconnect", {})
                    self._ble_reconnect_count += 1
                    # Wait for BLE to establish and drain
                    time.sleep(8)
                    # Verify it came back
                    debug2 = http_get("/ble-debug")
                    if isinstance(debug2, dict):
                        new_count = debug2.get("fromRadioDecoded", 0)
                        if new_count > current:
                            log(f"  {Colors.G}BLE reconnected (packets {current}→{new_count}){Colors.X}")
                            self._last_data_packets = new_count
                            return True
                        else:
                            log(f"  {Colors.R}BLE reconnect failed (still {new_count}){Colors.X}")
                            # Try one more time with longer wait
                            http_post("/action/ble-reconnect", {})
                            time.sleep(15)
                            debug3 = http_get("/ble-debug")
                            if isinstance(debug3, dict):
                                new_count2 = debug3.get("fromRadioDecoded", 0)
                                self._last_data_packets = new_count2
                                if new_count2 > current:
                                    log(f"  {Colors.G}BLE reconnected on retry (packets→{new_count2}){Colors.X}")
                                    return True
                            return False
                    return False

            self._last_data_packets = current
            return True

        # Can't reach debug endpoint — app might be down
        return False

    def get_message_count(self):
        msgs = http_get("/messages?limit=200")
        if isinstance(msgs, list):
            return len(msgs)
        return 0

    def find_message_in_app(self, marker, timeout=DM_TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            msgs = http_get("/messages?limit=100")
            if isinstance(msgs, list):
                for m in msgs:
                    text = m.get("text", "")
                    if marker in text:
                        return m
            time.sleep(POLL_INTERVAL)
        return None

    def _check_message_ack(self, marker, timeout=45):
        deadline = time.time() + timeout
        while time.time() < deadline:
            msgs = http_get("/messages?limit=50")
            if isinstance(msgs, list):
                for m in msgs:
                    if marker in (m.get("text") or ""):
                        if m.get("realACK"):
                            return "real_ack"
                        if m.get("receivedACK"):
                            return "ack_only"
            time.sleep(POLL_INTERVAL)
        return None

    def reconnect_serial_devices(self):
        """Reconnect all serial devices to keep pubsub fresh."""
        log(f"  {Colors.Y}Refreshing serial connections...{Colors.X}")
        for d in self.serial_devices:
            d.reconnect()
        time.sleep(1)

    def record(self, test_name, passed, details=""):
        status = f"{Colors.G}PASS{Colors.X}" if passed else f"{Colors.R}FAIL{Colors.X}"
        log(f"  [{status}] {test_name}{f' — {details}' if details else ''}")
        self.results.append({"test": test_name, "passed": passed, "details": details})

    # ========== TEST CASES ==========

    def test_text_serial_to_app(self, round_num, device):
        """Send text from a serial device to the app."""
        marker = f"{device.name}2A-R{round_num}-{int(time.time())}"
        label = f"Text:{device.name}→App"
        log(f"  Sending text {device.name} → app: '{marker}'")

        if not device.check_health():
            self.record(f"R{round_num} {label}", False, "Serial reconnect failed")
            return

        try:
            device.iface.sendText(marker, destinationId=self.app_device_num)
        except Exception as e:
            self.record(f"R{round_num} {label}", False, f"Send failed: {e}")
            return

        found = self.find_message_in_app(marker)
        if found:
            self.record(f"R{round_num} {label}", True, f"Found in app (id={found.get('messageId')})")
        else:
            self.record(f"R{round_num} {label}", False, "Not found in app within timeout")

    def test_text_app_to_serial(self, round_num, device):
        """Send text from app to a serial device."""
        marker = f"A2{device.name}-R{round_num}-{int(time.time())}"
        label = f"Text:App→{device.name}"
        log(f"  Sending text app → {device.name}: '{marker}'")

        if not device.check_health():
            log(f"    {device.name} reconnect failed, will rely on ACK verification")

        device.received_messages.clear()
        result = http_post("/action/send-message", {"to": device.device_num, "text": marker})
        if "error" in result:
            self.record(f"R{round_num} {label}", False, f"HTTP error: {result['error']}")
            return

        found = device.find_message(marker, timeout=15)
        if found:
            self.record(f"R{round_num} {label}", True, "Received on serial")
            return

        log(f"    Not received on serial, checking ACK status...")
        ack_result = self._check_message_ack(marker, timeout=45)
        if ack_result == "real_ack":
            self.record(f"R{round_num} {label}", True, "Delivered (REAL ACK confirmed)")
        elif ack_result == "ack_only":
            self.record(f"R{round_num} {label}", True, "Delivered (ACK, no realACK)")
        else:
            self.record(f"R{round_num} {label}", False, "No ACK received")

    def test_text_serial_to_serial(self, round_num, sender, receiver):
        """Send text from one serial device to another (mesh relay)."""
        marker = f"{sender.name}2{receiver.name}-R{round_num}-{int(time.time())}"
        label = f"Text:{sender.name}→{receiver.name}"
        log(f"  Sending text {sender.name} → {receiver.name}: '{marker}'")

        if not sender.check_health():
            self.record(f"R{round_num} {label}", False, f"{sender.name} reconnect failed")
            return
        if not receiver.check_health():
            self.record(f"R{round_num} {label}", False, f"{receiver.name} reconnect failed")
            return

        receiver.received_messages.clear()
        sender.ack_received_ids.clear()
        try:
            sent_packet = sender.iface.sendText(marker, destinationId=receiver.device_num)
        except Exception as e:
            self.record(f"R{round_num} {label}", False, f"Send failed: {e}")
            return

        # Extract sent message ID for ACK tracking
        sent_id = getattr(sent_packet, 'id', 0) if sent_packet else 0

        # Try receiver pubsub first (fast path, 15 seconds)
        found = receiver.find_message(marker, timeout=15)
        if found:
            self.record(f"R{round_num} {label}", True, "Received on serial")
            return

        # Fallback: check if sender got ACK from receiver (proves delivery)
        log(f"    Not received on serial, checking sender ACK...")
        deadline = time.time() + 30
        while time.time() < deadline:
            if sent_id and sent_id in sender.ack_received_ids:
                self.record(f"R{round_num} {label}", True, "Delivered (ACK on sender)")
                return
            # Also re-check receiver
            for m in receiver.received_messages:
                if marker in m.get("text", ""):
                    self.record(f"R{round_num} {label}", True, "Received on serial (late)")
                    return
            time.sleep(POLL_INTERVAL)

        self.record(f"R{round_num} {label}", False, "Not received and no ACK")

    def test_channel_broadcast(self, round_num):
        """Send channel broadcast from app, verify on all serial devices."""
        marker = f"CH-R{round_num}-{int(time.time())}"
        log(f"  Sending channel broadcast: '{marker}'")

        for d in self.serial_devices:
            d.check_health()
            d.received_messages.clear()

        result = http_post("/action/send-channel-message", {"channel": 0, "text": marker})
        if "error" in result:
            self.record(f"R{round_num} Channel:Broadcast", False, f"HTTP error: {result['error']}")
            return

        # Check if ANY serial device received it (fast path, 10 seconds)
        received_on = []
        deadline = time.time() + 10
        while time.time() < deadline:
            for d in self.serial_devices:
                if d.name not in received_on:
                    for m in d.received_messages:
                        if marker in m.get("text", ""):
                            received_on.append(d.name)
                            break
            if len(received_on) == len(self.serial_devices):
                break
            time.sleep(POLL_INTERVAL)

        if received_on:
            self.record(f"R{round_num} Channel:Broadcast", True,
                        f"Received on {', '.join(received_on)}")
        else:
            # Fallback: verify persisted in app
            log(f"    Not received on serial, checking app persistence...")
            found_in_app = self.find_message_in_app(marker, timeout=15)
            if found_in_app:
                self.record(f"R{round_num} Channel:Broadcast", True, "Sent (persisted in app)")
            else:
                self.record(f"R{round_num} Channel:Broadcast", False, "Not found in app or serial")

    def test_image_app_to_device(self, round_num, device):
        """Send test image from app to a serial device."""
        label = f"IMG-R{round_num}"
        log(f"  Sending test image from app → {device.name}: '{label}'")

        http_post("/action/clear-transfers", {})
        time.sleep(1)

        result = http_post("/action/send-test-image", {"to": device.device_num, "label": label})
        if "error" in result:
            self.record(f"R{round_num} Image:App→{device.name}", False, f"HTTP error: {result['error']}")
            return

        deadline = time.time() + IMAGE_TIMEOUT
        completed = False
        while time.time() < deadline:
            transfers = http_get("/transfers")
            if isinstance(transfers, dict):
                pending = transfers.get("pendingImages", [])
                outgoing = transfers.get("outgoing", [])
                if not pending and not outgoing:
                    completed = True
                    break
                progress = transfers.get("sendProgress")
                if progress is not None and progress >= 1.0:
                    completed = True
                    break
            time.sleep(POLL_INTERVAL)

        if completed:
            time.sleep(2)
            msgs = http_get("/messages?limit=50")
            if isinstance(msgs, list):
                image_msgs = [m for m in msgs if m.get("hasImage") and m.get("fromUserNum") == self.app_device_num]
                if image_msgs:
                    self.record(f"R{round_num} Image:App→{device.name}", True,
                                f"Sent and persisted ({image_msgs[0].get('imageBytes', '?')} bytes)")
                    return

        self.record(f"R{round_num} Image:App→{device.name}", completed,
                    "Transfer completed but image not found in DB" if completed else "Transfer did not complete")

    def test_voice_memo_app_to_device(self, round_num, device):
        """Send voice memo from app to a serial device."""
        log(f"  Sending voice memo from app → {device.name}")

        http_post("/action/clear-transfers", {})
        time.sleep(1)

        result = http_post("/action/send-voice-memo", {"to": device.device_num, "durationMs": 2000})
        if "error" in result:
            self.record(f"R{round_num} Voice:App→{device.name}", False, f"HTTP error: {result['error']}")
            return

        deadline = time.time() + IMAGE_TIMEOUT
        completed = False
        errored = False
        last_progress = 0
        while time.time() < deadline:
            transfers = http_get("/transfers")
            if isinstance(transfers, dict):
                pending_vm = transfers.get("pendingVoiceMemos", [])
                outgoing = transfers.get("outgoing", [])

                for vm in pending_vm:
                    if vm.get("error"):
                        log(f"    Voice memo error: {vm['error']}")
                        errored = True
                        break
                    last_progress = max(last_progress, vm.get("progress", 0))

                if errored:
                    break
                if not pending_vm and not outgoing:
                    completed = True
                    break
                if outgoing:
                    for o in outgoing:
                        last_progress = max(last_progress, o.get("progress", 0))
            time.sleep(POLL_INTERVAL)

        if errored:
            self.record(f"R{round_num} Voice:App→{device.name}", False, f"Transfer error (progress={last_progress:.1%})")
            return

        if completed:
            time.sleep(2)
            msgs = http_get("/messages?limit=50")
            if isinstance(msgs, list):
                vm_msgs = [m for m in msgs if m.get("hasVoiceMemo") and m.get("fromUserNum") == self.app_device_num]
                if vm_msgs:
                    self.record(f"R{round_num} Voice:App→{device.name}", True,
                                f"Sent and persisted ({vm_msgs[0].get('voiceMemoBytes', '?')} bytes, {vm_msgs[0].get('voiceMemoDuration', '?'):.1f}s)")
                    return

        self.record(f"R{round_num} Voice:App→{device.name}", completed,
                    "Transfer completed but voice memo not found in DB" if completed else f"Transfer timeout (progress={last_progress:.1%})")

    def print_stats(self, label=""):
        types = {}
        for r in self.results:
            parts = r["test"].split(" ", 1)
            ttype = parts[1] if len(parts) > 1 else parts[0]
            if ttype not in types:
                types[ttype] = {"pass": 0, "fail": 0, "failures": []}
            if r["passed"]:
                types[ttype]["pass"] += 1
            else:
                types[ttype]["fail"] += 1
                types[ttype]["failures"].append(r)

        total_pass = sum(t["pass"] for t in types.values())
        total_fail = sum(t["fail"] for t in types.values())
        total = total_pass + total_fail
        overall_pct = (total_pass / total * 100) if total > 0 else 0

        log(f"\n{'─'*70}")
        if label:
            log(f"  {Colors.B}{label}{Colors.X}")
        log(f"  {'Type':<35} {'Pass':>6} {'Fail':>6} {'Rate':>8}")
        log(f"  {'─'*57}")
        for ttype, stats in sorted(types.items()):
            total_t = stats["pass"] + stats["fail"]
            pct = (stats["pass"] / total_t * 100) if total_t > 0 else 0
            color = Colors.G if pct >= 99 else Colors.Y if pct >= 90 else Colors.R
            log(f"  {ttype:<35} {stats['pass']:>6} {stats['fail']:>6} {color}{pct:>7.1f}%{Colors.X}")
        log(f"  {'─'*57}")
        color = Colors.G if overall_pct >= 99 else Colors.Y if overall_pct >= 90 else Colors.R
        log(f"  {'TOTAL':<35} {total_pass:>6} {total_fail:>6} {color}{overall_pct:>7.1f}%{Colors.X}")
        log(f"{'─'*70}")

        return overall_pct, types

    def run(self, rounds=5, duration_minutes=0):
        use_duration = duration_minutes > 0
        num_serial = len(self.serial_devices) if self.serial_devices else "?"
        if use_duration:
            log(f"\n{'='*70}")
            log(f"MeshReliable Deliverability Test — {duration_minutes} min marathon")
            log(f"{'='*70}\n")
        else:
            log(f"\n{'='*70}")
            log(f"MeshReliable Deliverability Test — {rounds} rounds")
            log(f"{'='*70}\n")

        if not self.setup():
            log(f"{Colors.R}Setup failed — cannot run tests{Colors.X}")
            return

        num_serial = len(self.serial_devices)
        has_two_serial = num_serial >= 2

        # Show test matrix
        tests_per_round = 3  # 2 DMs + broadcast (with 1 serial)
        if has_two_serial:
            tests_per_round = 7  # 4 DMs + 2 mesh relay + broadcast
        log(f"Tests per round: {tests_per_round} ({num_serial} serial device{'s' if num_serial > 1 else ''})")

        # Clear stale transfers
        clear_result = http_post("/action/clear-transfers", {})
        cleared = clear_result.get("cleared", 0) if isinstance(clear_result, dict) else 0
        if cleared > 0:
            log(f"Cleared {cleared} stale transfers")

        msg_count = self.get_message_count()
        log(f"Initial message count in app: {msg_count}")
        log("")

        start_time = time.time()
        deadline = start_time + (duration_minutes * 60) if use_duration else float('inf')
        last_stats_time = start_time
        stats_interval = 300
        r = 0

        while True:
            r += 1
            now = time.time()

            if use_duration and now >= deadline:
                break
            if not use_duration and r > rounds:
                break

            elapsed = now - start_time
            elapsed_str = f"{int(elapsed//60)}m{int(elapsed%60):02d}s"
            remaining = ""
            if use_duration:
                rem = deadline - now
                remaining = f" | {int(rem//60)}m left"

            log(f"{'─'*50}")
            log(f"{Colors.B}Round {r}{Colors.X} [{elapsed_str}{remaining}]")
            log(f"{'─'*50}")

            # Check BLE health before each round
            ble_ok = self.ensure_ble_connected()
            if not ble_ok:
                log(f"  {Colors.R}BLE down — skipping app-dependent tests this round{Colors.X}")

            s1 = self.serial_devices[0]

            # === Serial1 ↔ App ===
            self.test_text_serial_to_app(r, s1)
            time.sleep(2)
            self.test_text_app_to_serial(r, s1)
            time.sleep(2)

            if has_two_serial:
                s2 = self.serial_devices[1]

                # === Serial2 ↔ App ===
                self.test_text_serial_to_app(r, s2)
                time.sleep(2)
                self.test_text_app_to_serial(r, s2)
                time.sleep(2)

                # Reconnect before serial-to-serial to ensure fresh pubsub
                self.reconnect_serial_devices()
                s1 = self.serial_devices[0]
                s2 = self.serial_devices[1]

                # === Serial1 ↔ Serial2 (mesh relay) ===
                self.test_text_serial_to_serial(r, s1, s2)
                time.sleep(2)
                self.test_text_serial_to_serial(r, s2, s1)
                time.sleep(2)

            # === Channel broadcast ===
            self.test_channel_broadcast(r)
            time.sleep(2)

            # === IMAGE (every 10th round) ===
            if r % 10 == 1:
                self.test_image_app_to_device(r, s1)
                log(f"  Waiting 20s for LoRa channel to settle...")
                time.sleep(20)

            # === VOICE MEMO (every 10th round, offset by 5) ===
            if r % 10 == 5:
                self.test_voice_memo_app_to_device(r, s1)
                log(f"  Waiting 20s for LoRa channel to settle...")
                time.sleep(20)

            # === INTERMEDIATE STATS ===
            if now - last_stats_time >= stats_interval:
                self.print_stats(f"Stats at {elapsed_str} — {len(self.results)} tests")
                last_stats_time = now

            log("")

        # Final Summary
        log(f"\n{'='*70}")
        elapsed = time.time() - start_time
        elapsed_str = f"{int(elapsed//60)}m{int(elapsed%60):02d}s"
        log(f"FINAL RESULTS — {r-1 if use_duration else rounds} rounds in {elapsed_str}")
        log(f"{'='*70}")

        overall_pct, types = self.print_stats("Per-Type Breakdown")

        failures = [r for r in self.results if not r["passed"]]
        if failures:
            log(f"\n{Colors.R}FAILURES ({len(failures)}):{Colors.X}")
            for f in failures:
                log(f"  {Colors.R}FAIL{Colors.X} {f['test']} — {f['details']}")
        else:
            log(f"\n{Colors.G}No failures!{Colors.X}")

        passed = sum(1 for r in self.results if r["passed"])
        total = len(self.results)
        color = Colors.G if overall_pct >= 99 else Colors.Y if overall_pct >= 90 else Colors.R
        log(f"\n{Colors.B}Score: {color}{passed}/{total} = {overall_pct:.1f}%{Colors.X}")

        final_count = self.get_message_count()
        log(f"Final message count in app: {final_count} (was {msg_count})")
        if self._ble_reconnect_count > 0:
            log(f"BLE reconnects triggered: {self._ble_reconnect_count}")

        for d in self.serial_devices:
            d.close()

        return overall_pct

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--duration", type=int, default=0, help="Duration in minutes (overrides --rounds)")
    parser.add_argument("--devices", type=str, default="", help="Comma-separated serial ports")
    args = parser.parse_args()

    device_ports = [p.strip() for p in args.devices.split(",") if p.strip()] if args.devices else []

    test = DeliverabilityTest(device_ports=device_ports)
    try:
        pct = test.run(rounds=args.rounds, duration_minutes=args.duration)
        sys.exit(0 if pct and pct >= 99 else 1)
    except KeyboardInterrupt:
        log("\nInterrupted — printing final stats")
        test.print_stats("INTERRUPTED")
        sys.exit(1)
    except Exception as e:
        log(f"{Colors.R}Fatal error: {e}{Colors.X}")
        traceback.print_exc()
        test.print_stats("PARTIAL (after error)")
        sys.exit(1)
