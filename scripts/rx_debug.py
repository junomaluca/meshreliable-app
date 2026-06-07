#!/usr/bin/env python3
"""Debug: check if T3-S3 serial interface forwards received packets."""

import os
import sys
import time
import threading

import meshtastic
import meshtastic.serial_interface
from pubsub import pub

XIAO_PORT = "/dev/cu.usbmodem101"
T3S3_PORT = "/dev/cu.usbmodem21201"

rx_events = []

def on_receive(packet, interface=None):
    port = getattr(interface, 'devPath', None) if interface else 'unknown'
    decoded = packet.get('decoded', {})
    portnum = decoded.get('portnum', '?')
    text = decoded.get('text', '')
    fromId = packet.get('fromId', '?')
    toId = packet.get('toId', '?')
    rx_events.append({
        'time': time.time(),
        'port': port,
        'portnum': portnum,
        'text': text,
        'from': fromId,
        'to': toId,
    })
    print(f"  RX on {port}: portnum={portnum} from={fromId} to={toId} text={text!r}", flush=True)

pub.subscribe(on_receive, "meshtastic.receive")

def ts():
    return time.strftime("%H:%M:%S")

print(f"[{ts()}] Connecting XIAO on {XIAO_PORT}...")
xiao = meshtastic.serial_interface.SerialInterface(XIAO_PORT, noNodes=True)
xiao_info = xiao.getMyNodeInfo()
xiao_num = xiao_info['num']
print(f"[{ts()}] XIAO: !{xiao_num:08x}, devPath={xiao.devPath}")

time.sleep(3)

print(f"[{ts()}] Connecting T3-S3 on {T3S3_PORT}...")
t3s3 = meshtastic.serial_interface.SerialInterface(T3S3_PORT, noNodes=True)
t3s3_info = t3s3.getMyNodeInfo()
t3s3_num = t3s3_info['num']
print(f"[{ts()}] T3-S3: !{t3s3_num:08x}, devPath={t3s3.devPath}")

time.sleep(5)

# Test 1: T3-S3 sends DM to XIAO
print(f"\n[{ts()}] TEST 1: T3-S3 → XIAO (DM)")
t3s3.sendText("RXD_test1_dm", destinationId=xiao_num, channelIndex=0)
time.sleep(15)

# Test 2: XIAO sends DM to T3-S3
print(f"\n[{ts()}] TEST 2: XIAO → T3-S3 (DM)")
rx_before = len(rx_events)
xiao.sendText("RXD_test2_dm", destinationId=t3s3_num, channelIndex=0)
time.sleep(15)

# Test 3: XIAO sends channel broadcast
print(f"\n[{ts()}] TEST 3: XIAO → channel (broadcast)")
xiao.sendText("RXD_test3_ch", channelIndex=0)
time.sleep(15)

# Test 4: T3-S3 sends channel broadcast
print(f"\n[{ts()}] TEST 4: T3-S3 → channel (broadcast)")
t3s3.sendText("RXD_test4_ch", channelIndex=0)
time.sleep(15)

print(f"\n[{ts()}] === SUMMARY ===")
print(f"Total RX events: {len(rx_events)}")
for i, ev in enumerate(rx_events):
    print(f"  {i+1}. port={ev['port']} portnum={ev['portnum']} "
          f"from={ev['from']} to={ev['to']} text={ev['text']!r}")

# Check which ports received
xiao_rx = [e for e in rx_events if e['port'] == XIAO_PORT and 'RXD_' in e.get('text', '')]
t3s3_rx = [e for e in rx_events if e['port'] == T3S3_PORT and 'RXD_' in e.get('text', '')]
print(f"\nXIAO received {len(xiao_rx)} test messages")
print(f"T3-S3 received {len(t3s3_rx)} test messages")

xiao.close()
t3s3.close()
print(f"\n[{ts()}] Done.")
