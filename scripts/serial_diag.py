#!/usr/bin/env python3
"""Diagnose serial breakdown: track raw bytes, pubsub events, thread health."""

import os
import sys
import time
import random
import string
import threading

import meshtastic
import meshtastic.serial_interface
from meshtastic.stream_interface import StreamInterface
from pubsub import pub

XIAO_PORT = "/dev/cu.usbmodem101"
T3S3_PORT = "/dev/cu.usbmodem21201"

def ts():
    return time.strftime("%H:%M:%S")

def nonce():
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=4))

# Track all pubsub events
event_count = {"xiao": 0, "t3s3": 0, "text_xiao": 0, "text_t3s3": 0}
last_event_time = {"xiao": 0, "t3s3": 0}
delivered = {}

def on_receive(packet, interface=None):
    port = getattr(interface, 'devPath', None) if interface else None
    decoded = packet.get('decoded', {})
    portnum = decoded.get('portnum', 'RAW')
    text = decoded.get('text', '')

    if port == XIAO_PORT:
        event_count["xiao"] += 1
        last_event_time["xiao"] = time.time()
        if portnum == 'TEXT_MESSAGE_APP' and text.startswith('SD_'):
            event_count["text_xiao"] += 1
            delivered[text] = ("xiao", time.time())
    elif port == T3S3_PORT:
        event_count["t3s3"] += 1
        last_event_time["t3s3"] = time.time()
        if portnum == 'TEXT_MESSAGE_APP' and text.startswith('SD_'):
            event_count["text_t3s3"] += 1
            delivered[text] = ("t3s3", time.time())

_ref = on_receive
pub.subscribe(on_receive, "meshtastic.receive")

# Connect
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

print(f"[{ts()}] Warmup done. Events so far: xiao={event_count['xiao']} t3s3={event_count['t3s3']}")

# Track meshtastic internal threads
def check_threads():
    threads = {}
    for t in threading.enumerate():
        threads[t.name] = t.is_alive()
    return threads

passed = 0
failed = 0

for i in range(50):
    if i % 2 == 0:
        sender, s_name, dest, r_name, r_port = xiao, "XIAO", t3s3_num, "T3-S3", T3S3_PORT
        r_key = "t3s3"
    else:
        sender, s_name, dest, r_name, r_port = t3s3, "T3-S3", xiao_num, "XIAO", XIAO_PORT
        r_key = "xiao"

    text = f"SD_{nonce()}_{i}"
    evt_before_xiao = event_count["xiao"]
    evt_before_t3s3 = event_count["t3s3"]

    try:
        sender.sendText(text, destinationId=dest, channelIndex=0)
    except Exception as e:
        print(f"[{ts()}] #{i+1:3d} SEND ERROR: {e}")
        failed += 1
        time.sleep(15)
        continue

    start = time.time()
    ok = False
    while time.time() - start < 20:
        if text in delivered:
            lat = delivered[text][1] - start
            passed += 1
            ok = True
            break
        time.sleep(0.3)

    evt_delta_xiao = event_count["xiao"] - evt_before_xiao
    evt_delta_t3s3 = event_count["t3s3"] - evt_before_t3s3

    # Thread health
    xiao_rx = xiao._rxThread.is_alive() if hasattr(xiao, '_rxThread') and xiao._rxThread else '?'
    t3s3_rx = t3s3._rxThread.is_alive() if hasattr(t3s3, '_rxThread') and t3s3._rxThread else '?'

    if ok:
        print(f"[{ts()}] #{i+1:3d} ✓ {s_name:6s}→{r_name:6s} ({lat:.1f}s) "
              f"events:x={evt_delta_xiao}/t={evt_delta_t3s3} "
              f"total:x={event_count['xiao']}/t={event_count['t3s3']} "
              f"rx:x={xiao_rx}/t={t3s3_rx} "
              f"[{passed}/{passed+failed}={passed/(passed+failed)*100:.0f}%]")
    else:
        failed += 1
        # More detailed diagnostics on failure
        age_xiao = time.time() - last_event_time["xiao"] if last_event_time["xiao"] else 999
        age_t3s3 = time.time() - last_event_time["t3s3"] if last_event_time["t3s3"] else 999
        print(f"[{ts()}] #{i+1:3d} ✗ {s_name:6s}→{r_name:6s} TIMEOUT "
              f"events:x={evt_delta_xiao}/t={evt_delta_t3s3} "
              f"total:x={event_count['xiao']}/t={event_count['t3s3']} "
              f"rx:x={xiao_rx}/t={t3s3_rx} "
              f"last_evt_age:x={age_xiao:.0f}s/t={age_t3s3:.0f}s "
              f"[{passed}/{passed+failed}={passed/(passed+failed)*100:.0f}%]")

    time.sleep(15)

rate = passed / (passed + failed) * 100 if (passed + failed) else 0
print(f"\n[{ts()}] DONE: {passed}/{passed+failed} ({rate:.1f}%)")
print(f"Text messages received: xiao={event_count['text_xiao']} t3s3={event_count['text_t3s3']}")
print(f"Total events: xiao={event_count['xiao']} t3s3={event_count['t3s3']}")
xiao.close()
t3s3.close()
