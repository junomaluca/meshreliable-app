#!/usr/bin/env python3
"""Debug: log ALL packets from both interfaces to understand why messages stop arriving."""

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

def ts():
    return time.strftime("%H:%M:%S")

packet_count = [0]

def on_any_receive(packet, interface=None):
    packet_count[0] += 1
    port = getattr(interface, 'devPath', '?') if interface else '?'
    decoded = packet.get('decoded', {})
    portnum = decoded.get('portnum', 'RAW')
    text = decoded.get('text', '')
    fromId = packet.get('fromId', '?')
    toId = packet.get('toId', '?')
    rxTime = packet.get('rxTime', '')

    # Highlight text messages
    marker = "***" if portnum == 'TEXT_MESSAGE_APP' else "   "
    print(f"  {marker} PKT#{packet_count[0]:3d} on {port[-5:]:>5s} | {portnum:24s} | "
          f"from={str(fromId):12s} to={str(toId):12s} | text={text!r}", flush=True)

_ref1 = on_any_receive
pub.subscribe(on_any_receive, "meshtastic.receive")

# Also subscribe to connection events
def on_connection(interface, topic=pub.AUTO_TOPIC):
    port = getattr(interface, 'devPath', '?') if interface else '?'
    print(f"  [CONN] {topic.getName()} on {port}", flush=True)

_ref2 = on_connection
try:
    pub.subscribe(on_connection, "meshtastic.connection.established")
    pub.subscribe(on_connection, "meshtastic.connection.lost")
except Exception:
    pass

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

print(f"\n[{ts()}] === Sending 5 DMs with 30s gaps ===\n")

for i in range(5):
    n = ''.join(random.choices(string.ascii_lowercase, k=4))

    if i % 2 == 0:
        sender, s_name, dest, r_name, r_port = xiao, "XIAO", t3s3_num, "T3-S3", T3S3_PORT
    else:
        sender, s_name, dest, r_name, r_port = t3s3, "T3-S3", xiao_num, "XIAO", XIAO_PORT

    text = f"PD_{n}_{i}"
    pkt_before = packet_count[0]

    print(f"[{ts()}] MSG #{i+1}: {s_name} → {r_name} text={text!r}")
    try:
        sender.sendText(text, destinationId=dest, channelIndex=0)
    except Exception as e:
        print(f"[{ts()}]   SEND EXCEPTION: {e}")
        time.sleep(30)
        continue

    # Wait 25s for delivery
    start = time.time()
    delivered = False
    while time.time() - start < 25:
        time.sleep(0.5)

    pkts_during = packet_count[0] - pkt_before
    print(f"[{ts()}]   Packets seen during wait: {pkts_during}")
    print(f"[{ts()}]   Waiting 30s before next...\n")
    time.sleep(30)

# Check thread status
print(f"\n[{ts()}] === Interface thread status ===")
for name, iface in [("XIAO", xiao), ("T3-S3", t3s3)]:
    stream = getattr(iface, '_rxThread', None)
    if stream:
        print(f"  {name} _rxThread alive: {stream.is_alive()}")
    else:
        print(f"  {name} _rxThread: None")

print(f"\n[{ts()}] Total packets seen: {packet_count[0]}")
xiao.close()
t3s3.close()
print(f"[{ts()}] Done.")
