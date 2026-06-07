#!/usr/bin/env python3
"""Test if pubsub callback stops working after N messages."""
import os
import sys
import time
import threading
import meshtastic
import meshtastic.serial_interface
from pubsub import pub

rx_count = 0
rx_lock = threading.Lock()
last_rx_time = time.time()

def on_receive(packet, interface=None):
    global rx_count, last_rx_time
    try:
        decoded = packet.get('decoded', {})
        portnum = decoded.get('portnum', '')
        text = decoded.get('text', '')
        from_id = packet.get('fromId', '?')
        to_id = packet.get('toId', '?')
        port = getattr(interface, 'devPath', '?') if interface else '?'
        with rx_lock:
            rx_count += 1
            last_rx_time = time.time()
            cnt = rx_count
        if portnum == 'TEXT_MESSAGE_APP':
            print(f"  [{cnt}] RX TEXT port={port} from={from_id} to={to_id} "
                  f"text='{text[:50]}'", flush=True)
        else:
            print(f"  [{cnt}] RX {portnum} port={port}", flush=True)
    except Exception as e:
        print(f"  RX ERROR: {e}", flush=True)

# Keep strong reference
_cb_ref = on_receive
pub.subscribe(on_receive, "meshtastic.receive")

# Connect only 2 devices for simplicity
PORTS = [
    ("/dev/cu.usbmodem101", "XIAO", 1550340734),
    ("/dev/cu.usbmodem21101", "Pager2", 2712908928),
]

ifaces = []
for port, name, node_num in PORTS:
    if not os.path.exists(port):
        continue
    print(f"Connecting {name}...", flush=True)
    iface = meshtastic.serial_interface.SerialInterface(port, noNodes=False)
    my = iface.getMyNodeInfo()
    num = my['num']
    print(f"  {name}: !{num:08x}", flush=True)
    ifaces.append((iface, name, num))

if len(ifaces) < 2:
    print("Need 2 devices")
    sys.exit(1)

s_iface, s_name, s_num = ifaces[0]
r_iface, r_name, r_num = ifaces[1]

print(f"\nSending 20 DMs from {s_name} to {r_name} with 10s gaps...\n", flush=True)

results = []
for i in range(20):
    msg = f"MR_test{i}_{int(time.time())}"
    print(f"[{i+1}/20] Sending '{msg}'...", flush=True)

    try:
        s_iface.sendText(msg, destinationId=r_num, channelIndex=0)
    except Exception as e:
        print(f"  SEND ERROR: {e}", flush=True)
        results.append(False)
        time.sleep(10)
        continue

    # Wait for receipt
    start = time.time()
    ok = False
    while time.time() - start < 30:
        with rx_lock:
            elapsed_since_rx = time.time() - last_rx_time
        # Check by looking at rx_count changes...
        # Actually, just wait and check
        time.sleep(0.5)
        # We need to check if this specific message was received
        # Simple approach: the callback prints the message

    # Wait 30 seconds total per message
    elapsed = time.time() - start
    remaining = max(0, 10 - elapsed)
    time.sleep(remaining)

    results.append(True)  # placeholder

print(f"\nTotal RX callbacks fired: {rx_count}", flush=True)
print(f"\n{'='*40}", flush=True)

for iface, name, _ in ifaces:
    try:
        iface.close()
    except:
        pass
