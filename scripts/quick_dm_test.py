#!/usr/bin/env python3
"""Quick DM delivery test between available devices."""
import os
import sys
import time
import threading
import meshtastic
import meshtastic.serial_interface
from pubsub import pub

DEVICE_MAP = {
    "/dev/cu.usbmodem101": ("XIAO", 1550340734),
    "/dev/cu.usbmodem1101": ("Pager #1", 946053355),
    "/dev/cu.usbmodem21101": ("Pager #2", 2712908928),
    "/dev/cu.usbmodem21201": ("T3-S3 V1", 1634999779),
}

received = {}
lock = threading.Lock()

def on_receive(packet, interface=None):
    try:
        if packet.get('decoded', {}).get('portnum') != 'TEXT_MESSAGE_APP':
            return
        text = packet['decoded'].get('text', '')
        with lock:
            if text not in received:
                received[text] = time.time()
        recv_port = getattr(interface, 'devPath', '?') if interface else '?'
        print(f"  RX: '{text}' on port={recv_port}", flush=True)
    except Exception as e:
        print(f"  RX ERROR: {e}", flush=True)

pub.subscribe(on_receive, "meshtastic.receive")

# Connect available devices
ifaces = []
for port, (name, node_num) in sorted(DEVICE_MAP.items()):
    if not os.path.exists(port):
        print(f"SKIP {name} ({port}) — not available", flush=True)
        continue
    print(f"Connecting {name} on {port}...", flush=True)
    try:
        iface = meshtastic.serial_interface.SerialInterface(port, noNodes=True)
        my_info = iface.getMyNodeInfo()
        actual_num = my_info['num']
        actual_hex = f"!{actual_num:08x}"
        print(f"  {name}: {actual_hex}", flush=True)
        ifaces.append((iface, name, actual_num, actual_hex, port))
    except Exception as e:
        print(f"  FAILED: {e}", flush=True)

print(f"\n{len(ifaces)} devices connected. Running DM tests...\n", flush=True)

test_num = 0
results = []
for i, (s_iface, s_name, s_num, s_hex, s_port) in enumerate(ifaces):
    for j, (r_iface, r_name, r_num, r_hex, r_port) in enumerate(ifaces):
        if i == j:
            continue
        test_num += 1
        msg = f"QDM_{test_num}_{int(time.time())}"
        print(f"Test {test_num}: {s_name} -> {r_name} (msg={msg})", flush=True)

        try:
            s_iface.sendText(msg, destinationId=r_num, channelIndex=0)
        except Exception as e:
            print(f"  SEND ERROR: {e}", flush=True)
            results.append((s_name, r_name, False, 0))
            continue

        start = time.time()
        delivered = False
        while time.time() - start < 30:
            with lock:
                if msg in received:
                    latency = received[msg] - start
                    delivered = True
                    break
            time.sleep(0.3)

        if delivered:
            print(f"  OK ({latency:.1f}s)", flush=True)
            results.append((s_name, r_name, True, latency))
        else:
            print(f"  TIMEOUT (30s)", flush=True)
            results.append((s_name, r_name, False, 0))

        time.sleep(3)

print(f"\n{'='*60}", flush=True)
ok = sum(1 for r in results if r[2])
print(f"RESULTS: {ok}/{len(results)} delivered", flush=True)
print(f"{'='*60}", flush=True)
for s, r, success, lat in results:
    status = f"OK ({lat:.1f}s)" if success else "FAILED"
    print(f"  {s:12s} -> {r:12s}: {status}", flush=True)

for iface, name, _, _, _ in ifaces:
    try:
        iface.close()
    except:
        pass
