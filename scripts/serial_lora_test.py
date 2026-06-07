#!/usr/bin/env python3
"""
Serial-to-Serial LoRa Reliability Test — No phone app required.

Tests message delivery between two USB-connected Meshtastic devices via LoRa.
Uses serial interfaces only, bypassing the BLE/phone app layer.

Test matrix per round (4 tests):
  1. DM: Device A → Device B
  2. DM: Device B → Device A
  3. Channel broadcast from Device A (verify on B)
  4. Channel broadcast from Device B (verify on A)

Usage:
    python3 -u serial_lora_test.py --duration 120
    python3 -u serial_lora_test.py --duration 300 --portA /dev/cu.usbmodem21101 --portB /dev/cu.usbmodem21201
"""

import argparse
import time
import threading
import sys

import meshtastic.serial_interface
from pubsub import pub

DM_TIMEOUT = 20.0
BCAST_TIMEOUT = 15.0
SETTLE_TIME = 10

class Colors:
    G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; C = "\033[96m"; B = "\033[1m"; X = "\033[0m"

def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


class SerialDevice:
    def __init__(self, port, name):
        self.port = port
        self.name = name
        self.iface = None
        self.node_num = None
        self.received = []  # list of (from_num, text, timestamp)
        self.lock = threading.Lock()

    def connect(self):
        log(f"  Connecting {self.name} on {self.port}...")
        self.iface = meshtastic.serial_interface.SerialInterface(self.port, noNodes=True)
        time.sleep(2)
        self.node_num = self.iface.myInfo.my_node_num
        log(f"  {self.name} connected: nodeNum={self.node_num}")

    def close(self):
        if self.iface:
            try:
                self.iface.close()
            except:
                pass

    def on_receive(self, packet, interface):
        if interface is not self.iface:
            return
        text = packet.get('decoded', {}).get('text', '')
        from_num = packet.get('from', 0)
        if text:
            with self.lock:
                self.received.append((from_num, text, time.time()))

    def find_message(self, marker, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for from_num, text, ts in self.received:
                    if marker in text:
                        return True
            time.sleep(0.5)
        return False

    def clear_received(self):
        with self.lock:
            self.received.clear()

    def reconnect(self):
        try:
            self.close()
        except:
            pass
        time.sleep(1)
        self.connect()


class LoRaTest:
    def __init__(self, devA, devB, duration_min):
        self.devA = devA
        self.devB = devB
        self.duration = duration_min * 60
        self.results = []
        self.start_time = None
        self._on_rx = None  # prevent GC of pubsub callback

    def setup(self):
        log("=== SETUP ===")
        self.devA.connect()
        self.devB.connect()

        # Subscribe to pubsub — store reference on self to prevent
        # garbage collection (PyPubSub uses weak references)
        def on_rx(packet, interface):
            self.devA.on_receive(packet, interface)
            self.devB.on_receive(packet, interface)
        self._on_rx = on_rx
        pub.subscribe(self._on_rx, "meshtastic.receive")

        log(f"\nDevice map:")
        log(f"  {self.devA.name}: {self.devA.port} → node {self.devA.node_num}")
        log(f"  {self.devB.name}: {self.devB.port} → node {self.devB.node_num}")
        log(f"  Tests per round: 4")
        return True

    def record(self, test_name, passed, details=""):
        status = f"{Colors.G}PASS{Colors.X}" if passed else f"{Colors.R}FAIL{Colors.X}"
        log(f"  [{status}] {test_name}{f' — {details}' if details else ''}")
        self.results.append({"test": test_name, "passed": passed, "details": details})

    def test_dm(self, round_num, sender, receiver):
        marker = f"{sender.name}2{receiver.name}-R{round_num}-{int(time.time())}"
        label = f"DM:{sender.name}→{receiver.name}"
        log(f"  Sending DM {sender.name} → {receiver.name}: '{marker}'")

        receiver.clear_received()
        try:
            sender.iface.sendText(marker, destinationId=receiver.node_num)
        except Exception as e:
            self.record(f"R{round_num} {label}", False, f"Send error: {e}")
            return

        found = receiver.find_message(marker, DM_TIMEOUT)
        self.record(f"R{round_num} {label}", found,
                    "Received" if found else "Not received within timeout")

    def test_broadcast(self, round_num, sender, receiver):
        marker = f"CH-{sender.name}-R{round_num}-{int(time.time())}"
        label = f"Bcast:{sender.name}→{receiver.name}"
        log(f"  Sending broadcast from {sender.name}: '{marker}'")

        receiver.clear_received()
        try:
            sender.iface.sendText(marker)
        except Exception as e:
            self.record(f"R{round_num} {label}", False, f"Send error: {e}")
            return

        found = receiver.find_message(marker, BCAST_TIMEOUT)
        self.record(f"R{round_num} {label}", found,
                    "Received" if found else "Not received within timeout")

    def run_round(self, round_num):
        elapsed = int(time.time() - self.start_time)
        remaining = max(0, int(self.duration - elapsed)) // 60
        log(f"\n{'─' * 50}")
        log(f"{Colors.B}Round {round_num}{Colors.X} [{elapsed // 60}m{elapsed % 60:02d}s | {remaining}m left]")
        log(f"{'─' * 50}")

        self.test_dm(round_num, self.devA, self.devB)
        self.test_dm(round_num, self.devB, self.devA)
        self.test_broadcast(round_num, self.devA, self.devB)
        self.test_broadcast(round_num, self.devB, self.devA)

        log(f"  Waiting {SETTLE_TIME}s for LoRa channel to settle...")
        time.sleep(SETTLE_TIME)

    def print_summary(self):
        total = len(self.results)
        passed = sum(1 for r in self.results if r['passed'])
        failed = total - passed
        elapsed = int(time.time() - self.start_time)

        log(f"\n{'=' * 60}")
        log(f"{Colors.B}FINAL RESULTS{Colors.X}")
        log(f"{'=' * 60}")
        log(f"Duration: {elapsed // 60}m{elapsed % 60:02d}s")
        log(f"Total tests: {total}")
        log(f"Passed: {Colors.G}{passed}{Colors.X} ({100 * passed / max(total, 1):.1f}%)")
        log(f"Failed: {Colors.R}{failed}{Colors.X}")

        # Per-test-type breakdown
        test_types = {}
        for r in self.results:
            # Extract test type from name (e.g., "R1 DM:A→B" → "DM:A→B")
            parts = r['test'].split(' ', 1)
            ttype = parts[1] if len(parts) > 1 else r['test']
            if ttype not in test_types:
                test_types[ttype] = {'passed': 0, 'total': 0}
            test_types[ttype]['total'] += 1
            if r['passed']:
                test_types[ttype]['passed'] += 1

        log(f"\nPer-test breakdown:")
        for ttype, stats in sorted(test_types.items()):
            pct = 100 * stats['passed'] / max(stats['total'], 1)
            color = Colors.G if pct >= 95 else Colors.Y if pct >= 80 else Colors.R
            log(f"  {ttype}: {color}{stats['passed']}/{stats['total']} ({pct:.0f}%){Colors.X}")

        if failed > 0:
            log(f"\nFailed tests:")
            for r in self.results:
                if not r['passed']:
                    log(f"  {Colors.R}✗{Colors.X} {r['test']} — {r['details']}")

    def run(self):
        self.start_time = time.time()
        round_num = 0

        log(f"\n{'=' * 60}")
        log(f"Serial LoRa Reliability Test — {self.duration // 60} min marathon")
        log(f"{'=' * 60}\n")

        if not self.setup():
            return

        try:
            while time.time() - self.start_time < self.duration:
                round_num += 1
                self.run_round(round_num)
        except KeyboardInterrupt:
            log(f"\n{Colors.Y}Interrupted after {round_num} rounds{Colors.X}")
        except Exception as e:
            log(f"\n{Colors.R}Error: {e}{Colors.X}")
            import traceback
            traceback.print_exc()
        finally:
            self.print_summary()
            self.devA.close()
            self.devB.close()

        return self.results


def main():
    parser = argparse.ArgumentParser(description="Serial LoRa Reliability Test")
    parser.add_argument("--duration", type=int, default=60, help="Duration in minutes (default: 60)")
    parser.add_argument("--portA", default="/dev/cu.usbmodem21101", help="Serial port for device A")
    parser.add_argument("--portB", default="/dev/cu.usbmodem21201", help="Serial port for device B")
    parser.add_argument("--nameA", default="Pager", help="Name for device A")
    parser.add_argument("--nameB", default="T3-S3", help="Name for device B")
    args = parser.parse_args()

    devA = SerialDevice(args.portA, args.nameA)
    devB = SerialDevice(args.portB, args.nameB)

    test = LoRaTest(devA, devB, args.duration)
    test.run()


if __name__ == "__main__":
    main()
