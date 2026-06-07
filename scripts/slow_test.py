#!/usr/bin/env python3
"""Minimal slow DM test — 1 message per 30s to rule out airtime exhaustion."""

import os
import sys
import time
import random
import string
import threading

import meshtastic
import meshtastic.serial_interface
from pubsub import pub

XIAO_PORT = "/dev/cu.usbmodem101"
T3S3_PORT = "/dev/cu.usbmodem21201"

_received = {}
_rx_lock = threading.Lock()

def _on_receive(packet, interface=None):
    try:
        decoded = packet.get('decoded', {})
        if decoded.get('portnum') != 'TEXT_MESSAGE_APP':
            return
        text = decoded.get('text', '')
        if not text or not text.startswith('ST_'):
            return
        port = getattr(interface, 'devPath', None) if interface else None
        with _rx_lock:
            if text not in _received:
                _received[text] = []
            _received[text].append((time.time(), port))
    except Exception:
        pass

_cb_ref = _on_receive
pub.subscribe(_on_receive, "meshtastic.receive")

def ts():
    return time.strftime("%H:%M:%S")

def nonce():
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))

# Connect both once
print(f"[{ts()}] Connecting XIAO...")
xiao = meshtastic.serial_interface.SerialInterface(XIAO_PORT, noNodes=True)
xiao_num = xiao.getMyNodeInfo()['num']
print(f"[{ts()}] XIAO: !{xiao_num:08x}")

time.sleep(3)

print(f"[{ts()}] Connecting T3-S3...")
t3s3 = meshtastic.serial_interface.SerialInterface(T3S3_PORT, noNodes=True)
t3s3_num = t3s3.getMyNodeInfo()['num']
print(f"[{ts()}] T3-S3: !{t3s3_num:08x}")

time.sleep(10)
print(f"[{ts()}] Warmup done. Starting slow test (30s between messages)...")

passed = 0
failed = 0

for i in range(100):
    # Alternate direction
    if i % 2 == 0:
        sender, s_name, receiver_port, dest_num = xiao, "XIAO", T3S3_PORT, t3s3_num
        r_name = "T3-S3"
    else:
        sender, s_name, receiver_port, dest_num = t3s3, "T3-S3", XIAO_PORT, xiao_num
        r_name = "XIAO"

    text = f"ST_{nonce()}"
    try:
        sender.sendText(text, destinationId=dest_num, channelIndex=0)
    except Exception as e:
        print(f"[{ts()}] #{i+1:3d} SEND ERROR {s_name}→{r_name}: {e}")
        failed += 1
        time.sleep(30)
        continue

    start = time.time()
    ok = False
    while time.time() - start < 25:
        with _rx_lock:
            for t, p in _received.get(text, []):
                if p == receiver_port:
                    lat = t - start
                    print(f"[{ts()}] #{i+1:3d} ✓ {s_name:6s} → {r_name:6s} ({lat:.1f}s)  "
                          f"[{passed+1}/{passed+failed+1} = {(passed+1)/(passed+failed+1)*100:.0f}%]")
                    passed += 1
                    ok = True
                    break
        if ok:
            break
        time.sleep(0.3)

    if not ok:
        failed += 1
        print(f"[{ts()}] #{i+1:3d} ✗ {s_name:6s} → {r_name:6s} TIMEOUT  "
              f"[{passed}/{passed+failed} = {passed/(passed+failed)*100:.0f}%]")

    # Wait 30s between messages
    time.sleep(30)

rate = passed / (passed + failed) * 100 if (passed + failed) else 0
print(f"\n[{ts()}] DONE: {passed}/{passed+failed} ({rate:.1f}%)")
xiao.close()
t3s3.close()
