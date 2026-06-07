#!/usr/bin/env python3
"""Debug: send media transfer from XIAO only, monitor T3-S3 serial separately."""
import os
import sys
import time
import random
import zlib

try:
    import meshtastic
    import meshtastic.serial_interface
    from pubsub import pub
except ImportError:
    print("pip install meshtastic")
    sys.exit(1)


# --- Protobuf encoding ---
MT_CHUNK = 0
MT_START = 1
MT_COMPLETE = 2
MT_ACK_COMPLETE = 4
CT_VOICE_MEMO = 0


def _encode_varint(value):
    result = bytearray()
    while value > 0x7F:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value & 0x7F)
    return bytes(result)

def _encode_field_varint(field_num, value):
    if value == 0:
        return b''
    tag = (field_num << 3) | 0
    return _encode_varint(tag) + _encode_varint(value)

def _encode_field_bytes(field_num, data):
    if not data:
        return b''
    tag = (field_num << 3) | 2
    return _encode_varint(tag) + _encode_varint(len(data)) + data

def encode_media_transfer(msg_type, transfer_id, chunk_index=0, total_chunks=0,
                           total_size=0, chunk_data=b'', content_type=0,
                           checksum=0, duration_seconds=0):
    buf = bytearray()
    buf += _encode_field_varint(1, msg_type)
    buf += _encode_field_varint(2, transfer_id)
    buf += _encode_field_varint(3, chunk_index)
    buf += _encode_field_varint(4, total_chunks)
    buf += _encode_field_varint(5, total_size)
    buf += _encode_field_bytes(6, chunk_data)
    buf += _encode_field_varint(7, content_type)
    buf += _encode_field_varint(9, checksum)
    buf += _encode_field_varint(11, duration_seconds)
    return bytes(buf)


# --- RX listener ---
all_rx = []

def on_rx(packet, interface=None):
    decoded = packet.get('decoded', {})
    portnum = decoded.get('portnum', '?')
    from_id = packet.get('fromId', '?')
    to_id = packet.get('toId', '?')
    payload = decoded.get('payload', b'')

    if portnum in ('POSITION_APP', 'TELEMETRY_APP', 'NODEINFO_APP',
                   'STORE_FORWARD_APP', 'NEIGHBORINFO_APP', 'TRACEROUTE_APP',
                   'MAP_REPORT_APP', 'ROUTING_APP', 'ADMIN_APP'):
        return

    print(f"  [RX] from={from_id} to={to_id} port={portnum} "
          f"len={len(payload) if isinstance(payload, bytes) else '?'}", flush=True)
    all_rx.append((portnum, from_id, to_id, payload))

pub.subscribe(on_rx, "meshtastic.receive")


XIAO_PORT = "/dev/cu.usbmodem101"
T3S3_NUM = 1634999779  # 0x61741de3


def main():
    print("Connecting XIAO only (monitor T3-S3 serial separately)...", flush=True)
    xiao = meshtastic.serial_interface.SerialInterface(XIAO_PORT)
    time.sleep(3)
    xiao_num = xiao.getMyNodeInfo().get('num', 0)
    print(f"  XIAO: {xiao_num} ({hex(xiao_num)})", flush=True)
    print(f"  Target T3-S3: {T3S3_NUM} ({hex(T3S3_NUM)})", flush=True)

    # --- 1-chunk voice transfer XIAO → T3-S3 ---
    print("\n=== Sending 1-chunk voice transfer XIAO → T3-S3 ===", flush=True)
    transfer_id = random.randint(1, 0xFFFFFFFF)
    voice_data = os.urandom(100)
    checksum = zlib.crc32(voice_data) & 0xFFFFFFFF
    print(f"  TID: {transfer_id}, CRC: {hex(checksum)}, size: {len(voice_data)}", flush=True)

    # START
    start_pb = encode_media_transfer(MT_START, transfer_id, total_chunks=1,
                                      total_size=len(voice_data), content_type=CT_VOICE_MEMO,
                                      checksum=checksum, duration_seconds=3)
    xiao.sendData(start_pb, destinationId=T3S3_NUM, portNum=259,
                  channelIndex=0, wantAck=False)
    print(f"  Sent START ({len(start_pb)} bytes): {start_pb.hex()}", flush=True)
    time.sleep(5)

    # CHUNK 0
    chunk_pb = encode_media_transfer(MT_CHUNK, transfer_id, chunk_index=0,
                                      chunk_data=voice_data)
    xiao.sendData(chunk_pb, destinationId=T3S3_NUM, portNum=259,
                  channelIndex=0, wantAck=False)
    print(f"  Sent CHUNK 0 ({len(chunk_pb)} bytes)", flush=True)
    print(f"  voice_data[0:16]: {voice_data[:16].hex(' ')}", flush=True)
    print(f"  chunk_pb hex: {chunk_pb.hex(' ')}", flush=True)
    time.sleep(5)

    # COMPLETE
    complete_pb = encode_media_transfer(MT_COMPLETE, transfer_id)
    xiao.sendData(complete_pb, destinationId=T3S3_NUM, portNum=259,
                  channelIndex=0, wantAck=False)
    print(f"  Sent COMPLETE ({len(complete_pb)} bytes): {complete_pb.hex()}", flush=True)

    # Wait for ACK_COMPLETE
    print(f"\n  Waiting 30s for ACK_COMPLETE from T3-S3...", flush=True)
    deadline = time.time() + 30
    got_ack = False
    while time.time() < deadline:
        for pkt in all_rx:
            if pkt[0] in (259, 'MEDIA_TRANSFER_APP'):
                got_ack = True
                break
        if got_ack:
            break
        time.sleep(0.5)

    if got_ack:
        print(f"  *** ACK_COMPLETE RECEIVED! ***", flush=True)
    else:
        print(f"  *** NO ACK_COMPLETE after 30s ***", flush=True)

    if all_rx:
        print(f"\n  All received packets:", flush=True)
        for p in all_rx:
            print(f"    port={p[0]} from={p[1]} to={p[2]}", flush=True)

    print("\nDone.", flush=True)
    xiao.close()


if __name__ == "__main__":
    main()
