#!/usr/bin/env python3
"""Simple 2-device DM test to isolate callback issues."""
import os
import sys
import time
import threading
import meshtastic
import meshtastic.serial_interface
from pubsub import pub

# Track received messages
received = {}
rx_lock = threading.Lock()
total_callbacks = 0

def on_receive(packet, interface=None):
    global total_callbacks
    try:
        decoded = packet.get('decoded', {})
        portnum = decoded.get('portnum', '')
        text = decoded.get('text', '')
        port = getattr(interface, 'devPath', '?') if interface else '?'

        with rx_lock:
            total_callbacks += 1
            cnt = total_callbacks

        if portnum == 'TEXT_MESSAGE_APP' and text:
            with rx_lock:
                received[text] = time.time()
            print(f"  [{cnt}] RX: '{text}' on {port}", flush=True)
    except Exception as e:
        print(f"  RX ERROR: {e}", flush=True)

_ref = on_receive
pub.subscribe(on_receive, "meshtastic.receive")

# Connect XIAO and Pager #2 with delay
port_a = "/dev/cu.usbmodem101"
port_b = "/dev/cu.usbmodem21101"

print("Connecting XIAO...", flush=True)
iface_a = meshtastic.serial_interface.SerialInterface(port_a, noNodes=True)
num_a = iface_a.getMyNodeInfo()['num']
print(f"  XIAO: !{num_a:08x}", flush=True)

print("Waiting 5s before connecting next device...", flush=True)
time.sleep(5)

print("Connecting Pager #2...", flush=True)
iface_b = meshtastic.serial_interface.SerialInterface(port_b, noNodes=True)
num_b = iface_b.getMyNodeInfo()['num']
print(f"  Pager: !{num_b:08x}", flush=True)

# Warmup — wait for devices to exchange NodeInfo
print("\nWaiting 15s for device warmup...", flush=True)
time.sleep(15)

print(f"\n=== Sending 20 alternating DMs (10s apart) ===\n", flush=True)

ok_count = 0
fail_count = 0
for i in range(20):
    if i % 2 == 0:
        sender, s_name, receiver_num, r_name = iface_a, "XIAO", num_b, "Pager"
    else:
        sender, s_name, receiver_num, r_name = iface_b, "Pager", num_a, "XIAO"

    msg = f"MR_t{i}_{int(time.time())}"
    print(f"[{i+1}/20] {s_name} → {r_name}: '{msg}'", flush=True)

    try:
        sender.sendText(msg, destinationId=receiver_num, channelIndex=0)
    except Exception as e:
        print(f"  SEND ERROR: {e}", flush=True)
        fail_count += 1
        time.sleep(10)
        continue

    start = time.time()
    delivered = False
    while time.time() - start < 30:
        with rx_lock:
            if msg in received:
                lat = received[msg] - start
                delivered = True
                break
        time.sleep(0.3)

    if delivered:
        print(f"  OK ({lat:.1f}s) [cb={total_callbacks}]", flush=True)
        ok_count += 1
    else:
        print(f"  TIMEOUT [cb={total_callbacks}]", flush=True)
        fail_count += 1

    time.sleep(10)

print(f"\n{'='*50}", flush=True)
print(f"RESULTS: {ok_count}/{ok_count+fail_count} delivered", flush=True)
print(f"Total callbacks: {total_callbacks}", flush=True)

iface_a.close()
iface_b.close()
