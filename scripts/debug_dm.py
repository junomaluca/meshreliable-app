#!/usr/bin/env python3
"""Debug script: test DM vs channel delivery, dump all received packets."""
import os
import sys
import time
import threading
import json
import meshtastic
import meshtastic.serial_interface
from pubsub import pub

PORTS = [
    ("/dev/cu.usbmodem101", "XIAO", 1550340734),
    ("/dev/cu.usbmodem21101", "Pager2", 2712908928),
    ("/dev/cu.usbmodem21201", "T3S3", 1634999779),
]

def on_receive_all(packet, interface=None):
    """Dump ALL received packets."""
    try:
        decoded = packet.get('decoded', {})
        portnum = decoded.get('portnum', '?')
        text = decoded.get('text', '')
        from_id = packet.get('fromId', '?')
        to_id = packet.get('toId', '?')
        port = getattr(interface, 'devPath', '?') if interface else '?'
        channel = packet.get('channel', '?')
        pki = packet.get('pkiEncrypted', False)

        if portnum == 'TEXT_MESSAGE_APP':
            print(f"  [RX TEXT] port={port} from={from_id} to={to_id} "
                  f"ch={channel} pki={pki} text='{text}'", flush=True)
        elif portnum in ('NODEINFO_APP', 'POSITION_APP', 'TELEMETRY_APP',
                         'ROUTING_APP', 'STORE_FORWARD_APP'):
            pass  # Skip noisy protocols
        else:
            print(f"  [RX {portnum}] port={port} from={from_id} to={to_id} "
                  f"ch={channel} pki={pki}", flush=True)
    except Exception as e:
        print(f"  [RX ERROR] {e}", flush=True)

pub.subscribe(on_receive_all, "meshtastic.receive")

# Connect
ifaces = []
for port, name, node_num in PORTS:
    if not os.path.exists(port):
        print(f"SKIP {name} ({port})", flush=True)
        continue
    print(f"Connecting {name} on {port}...", flush=True)
    try:
        iface = meshtastic.serial_interface.SerialInterface(port, noNodes=False)
        my = iface.getMyNodeInfo()
        num = my['num']
        has_pkc = my.get('hasPKC', False)
        pkc_key = my.get('user', {}).get('publicKey', '?')
        print(f"  {name}: !{num:08x} hasPKC={has_pkc} pubKey={pkc_key[:20]}...", flush=True)

        # Check node DB for other devices
        nodes = iface.nodes
        if nodes:
            print(f"  NodeDB has {len(nodes)} nodes:", flush=True)
            for nid, ninfo in nodes.items():
                uname = ninfo.get('user', {}).get('longName', '?')
                upk = ninfo.get('user', {}).get('publicKey', '')
                print(f"    {nid}: {uname} pubKey={upk[:20] if upk else 'NONE'}...", flush=True)
        else:
            print(f"  NodeDB is EMPTY!", flush=True)

        ifaces.append((iface, name, num))
    except Exception as e:
        print(f"  FAILED: {e}", flush=True)

if len(ifaces) < 2:
    print("Need at least 2 devices", flush=True)
    sys.exit(1)

print(f"\n--- TEST 1: Channel broadcast from {ifaces[0][1]} ---", flush=True)
s_iface, s_name, s_num = ifaces[0]
msg_ch = f"CH_TEST_{int(time.time())}"
print(f"Sending channel broadcast: '{msg_ch}'", flush=True)
s_iface.sendText(msg_ch, channelIndex=0)
time.sleep(10)

print(f"\n--- TEST 2: DM from {ifaces[0][1]} to {ifaces[1][1]} ---", flush=True)
r_iface, r_name, r_num = ifaces[1]
msg_dm = f"DM_TEST_{int(time.time())}"
print(f"Sending DM: '{msg_dm}' to !{r_num:08x}", flush=True)
s_iface.sendText(msg_dm, destinationId=r_num, channelIndex=0)
time.sleep(15)

print(f"\n--- TEST 3: DM from {ifaces[1][1]} to {ifaces[0][1]} ---", flush=True)
msg_dm2 = f"DM_TEST2_{int(time.time())}"
print(f"Sending DM: '{msg_dm2}' to !{s_num:08x}", flush=True)
r_iface.sendText(msg_dm2, destinationId=s_num, channelIndex=0)
time.sleep(15)

if len(ifaces) >= 3:
    print(f"\n--- TEST 4: DM from {ifaces[0][1]} to {ifaces[2][1]} ---", flush=True)
    t_iface, t_name, t_num = ifaces[2]
    msg_dm3 = f"DM_TEST3_{int(time.time())}"
    print(f"Sending DM: '{msg_dm3}' to !{t_num:08x}", flush=True)
    s_iface.sendText(msg_dm3, destinationId=t_num, channelIndex=0)
    time.sleep(15)

print("\n--- DONE ---", flush=True)
for iface, name, _ in ifaces:
    try:
        iface.close()
    except:
        pass
