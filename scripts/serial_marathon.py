#!/usr/bin/env python3
"""
MeshReliable Marathon — Multi-Device Deliverability Test.

Supports serial and BLE connections. Keeps persistent connections
(no reconnect per round). Supports 2-4 devices with pair rotation.

Test types per round:
  - DM: Text direct message (every pair)
  - ACK: Text DM with wantAck (1 random pair)
  - BIN: Binary data DM (1 random pair)
  - VMO: Voice memo via MediaTransfer — real Codec2 audio (1 random pair)
  - IMG: Image via MediaTransfer — real JPEG thumbnail (every 3rd round)
  - CH: Channel broadcast (each device → all others)

Usage:
  # Auto-detect serial devices, default 8h marathon, 1s delay:
  python3 -u serial_marathon.py

  # 2-hour marathon, custom delay:
  python3 -u serial_marathon.py --duration 2 --delay 2

  # Include BLE device (connects via Bluetooth):
  python3 -u serial_marathon.py --ble "T3-S3 V1"

  # Specify serial ports explicitly:
  python3 -u serial_marathon.py --ports /dev/cu.usbmodem101,/dev/cu.usbmodem1101
"""

import argparse
import os
import random
import string
import struct
import sys
import threading
import time
import traceback
import zlib
from collections import defaultdict

try:
    import meshtastic
    import meshtastic.serial_interface
    import meshtastic.tcp_interface
    from pubsub import pub
except ImportError:
    print("ERROR: pip install meshtastic")
    sys.exit(1)

try:
    from meshtastic.ble_interface import BLEInterface
    HAS_BLE = True
except ImportError:
    HAS_BLE = False

try:
    import numpy as np
    import pycodec2
    HAS_CODEC2 = True
except ImportError:
    HAS_CODEC2 = False
    print("WARNING: pycodec2/numpy not available — VMO tests will use random bytes")

try:
    from PIL import Image
    import io
    HAS_PILLOW = True
except ImportError:
    HAS_PILLOW = False
    print("WARNING: Pillow not available — IMG tests will use random bytes")


# --- Protobuf encoding for MediaTransfer (port 259) ---
MEDIA_TRANSFER_PORT = 259

# MediaTransferType enum
MT_CHUNK = 0
MT_START = 1
MT_COMPLETE = 2
MT_NACK = 3
MT_ACK_COMPLETE = 4
MT_CANCEL = 5

# MediaContentType enum
CT_VOICE_MEMO = 0
CT_IMAGE_THUMBNAIL = 1
CT_IMAGE_LOWRES = 2
CT_BINARY_DATA = 3


def generate_codec2_audio(duration_seconds=3, freq=440):
    """Generate real Codec2 Mode 1300 encoded audio (440Hz sine wave).

    Returns bytes that are genuine Codec2 frames — exactly what the firmware
    expects for voice memo playback.
    """
    if not HAS_CODEC2:
        # Fallback: random bytes sized like codec2 output
        num_frames = int(duration_seconds * 8000 / 320)
        return os.urandom(num_frames * 7)

    c2 = pycodec2.Codec2(1300)
    sample_rate = 8000
    spf = c2.samples_per_frame()  # 320
    total_samples = int(sample_rate * duration_seconds)

    # Generate sine wave
    t = np.arange(total_samples, dtype=np.float32)
    samples = (np.sin(2 * np.pi * freq * t / sample_rate) * 16000).astype(np.int16)

    # Encode frame by frame
    frames = []
    for i in range(0, total_samples - spf + 1, spf):
        encoded = c2.encode(samples[i:i + spf])
        frames.append(bytes(encoded))

    return b''.join(frames)


def generate_jpeg_thumbnail(width=80, height=60):
    """Generate a real JPEG thumbnail image with a simple gradient pattern.

    Returns bytes that are a valid JPEG file — exactly what the firmware
    expects for image thumbnail display.
    """
    if not HAS_PILLOW:
        return os.urandom(800)

    img = Image.new('RGB', (width, height))
    pixels = img.load()
    # Create a colorful gradient pattern (different each call)
    r_off = random.randint(0, 255)
    g_off = random.randint(0, 255)
    for y in range(height):
        for x in range(width):
            r = (x * 255 // width + r_off) % 256
            g = (y * 255 // height + g_off) % 256
            b = ((x + y) * 255 // (width + height)) % 256
            pixels[x, y] = (r, g, b)

    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=30)
    return buf.getvalue()


# Pre-generate some payloads to avoid regenerating every round
_cached_codec2 = None
_cached_jpeg = None


def get_voice_memo_payload():
    """Get a Codec2-encoded voice memo payload (~3 seconds, ~525 bytes)."""
    global _cached_codec2
    if _cached_codec2 is None:
        _cached_codec2 = generate_codec2_audio(duration_seconds=3, freq=440)
    return _cached_codec2


def get_image_payload():
    """Get a JPEG thumbnail payload (fresh each call for variety)."""
    return generate_jpeg_thumbnail(width=80, height=60)


def _encode_varint(value):
    """Encode an unsigned integer as a protobuf varint."""
    result = bytearray()
    while value > 0x7F:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value & 0x7F)
    return bytes(result)


def _encode_field_varint(field_num, value):
    """Encode a varint field (wire type 0)."""
    if value == 0:
        return b''  # proto3: skip default values
    tag = (field_num << 3) | 0  # wire type 0 = varint
    return _encode_varint(tag) + _encode_varint(value)


def _encode_field_bytes(field_num, data):
    """Encode a bytes/string field (wire type 2)."""
    if not data:
        return b''
    tag = (field_num << 3) | 2  # wire type 2 = length-delimited
    return _encode_varint(tag) + _encode_varint(len(data)) + data


def encode_media_transfer(msg_type, transfer_id, chunk_index=0, total_chunks=0,
                           total_size=0, chunk_data=b'', content_type=0,
                           checksum=0, duration_seconds=0, width=0, height=0):
    """Encode a MediaTransfer protobuf message."""
    buf = bytearray()
    # Field 1: type (enum)
    buf += _encode_field_varint(1, msg_type)
    # Field 2: transfer_id
    buf += _encode_field_varint(2, transfer_id)
    # Field 3: chunk_index
    buf += _encode_field_varint(3, chunk_index)
    # Field 4: total_chunks
    buf += _encode_field_varint(4, total_chunks)
    # Field 5: total_size
    buf += _encode_field_varint(5, total_size)
    # Field 6: chunk_data
    buf += _encode_field_bytes(6, chunk_data)
    # Field 7: content_type
    buf += _encode_field_varint(7, content_type)
    # Field 9: checksum
    buf += _encode_field_varint(9, checksum)
    # Field 11: duration_seconds
    buf += _encode_field_varint(11, duration_seconds)
    # Field 12: width
    buf += _encode_field_varint(12, width)
    # Field 13: height
    buf += _encode_field_varint(13, height)
    return bytes(buf)


def decode_media_transfer_header(data):
    """Decode just type and transfer_id from a MediaTransfer protobuf."""
    pos = 0
    msg_type = 0
    transfer_id = 0
    while pos < len(data):
        if pos >= len(data):
            break
        # Read tag
        tag_byte = data[pos]
        field_num = tag_byte >> 3
        wire_type = tag_byte & 0x07
        pos += 1
        if wire_type == 0:  # varint
            value = 0
            shift = 0
            while pos < len(data):
                b = data[pos]
                pos += 1
                value |= (b & 0x7F) << shift
                if not (b & 0x80):
                    break
                shift += 7
            if field_num == 1:
                msg_type = value
            elif field_num == 2:
                transfer_id = value
                return msg_type, transfer_id  # got both, done
        elif wire_type == 2:  # length-delimited
            length = 0
            shift = 0
            while pos < len(data):
                b = data[pos]
                pos += 1
                length |= (b & 0x7F) << shift
                if not (b & 0x80):
                    break
                shift += 7
            pos += length  # skip payload
        else:
            break  # unknown wire type
    return msg_type, transfer_id


class Colors:
    G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; C = "\033[96m"
    B = "\033[1m"; M = "\033[95m"; X = "\033[0m"


def ts():
    return time.strftime("%H:%M:%S")


def log(msg):
    print(f"[{ts()}] {msg}", flush=True)


def nonce(length=6):
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=length))


# Received messages: text -> list of (timestamp, port)
_received = {}
_rx_lock = threading.Lock()

# Media transfer ACK tracking: transfer_id -> (timestamp, port)
_media_acks = {}
_media_lock = threading.Lock()

# Global send lock — serialize all serial sends to avoid USB contention
_send_lock = threading.Lock()
_SEND_COOLDOWN = 0.3  # seconds between sends


def _get_iface_id(interface):
    """Get a unique identifier for an interface (serial port path, TCP hostname, or BLE address)."""
    if interface is None:
        return None
    return (getattr(interface, 'devPath', None)
            or getattr(interface, 'hostname', None)
            or getattr(interface, 'address', None)
            or id(interface))


def _on_receive(packet, interface=None):
    try:
        decoded = packet.get('decoded', {})
        portnum = decoded.get('portnum', '')
        port = _get_iface_id(interface)

        key = None
        if portnum == 'TEXT_MESSAGE_APP':
            text = decoded.get('text', '')
            if text and text.startswith('MR_'):
                key = text
        elif portnum == 'PRIVATE_APP':
            # Binary data test — extract marker from payload
            payload = decoded.get('payload', b'')
            if isinstance(payload, bytes) and payload.startswith(b'MR_'):
                key = payload.split(b'\x00')[0].decode('utf-8', errors='ignore')
        elif portnum in ('MEDIA_TRANSFER_APP', 259, '259') or str(portnum) == '259':
            # Media transfer protocol response — check for ACK_COMPLETE
            payload = decoded.get('payload', b'')
            if isinstance(payload, bytes) and len(payload) >= 2:
                msg_type, transfer_id = decode_media_transfer_header(payload)
                if msg_type == MT_ACK_COMPLETE and transfer_id and port:
                    with _media_lock:
                        _media_acks[transfer_id] = (time.time(), port)

        if key and port:
            with _rx_lock:
                if key not in _received:
                    _received[key] = []
                if not any(p == port for _, p in _received[key]):
                    _received[key].append((time.time(), port))
    except Exception:
        pass


_cb_ref = _on_receive
pub.subscribe(_on_receive, "meshtastic.receive")


def check_received(text, port):
    with _rx_lock:
        for t, p in _received.get(text, []):
            if p == port:
                return t
    return None


def check_media_ack(transfer_id):
    """Check if a media transfer ACK_COMPLETE has been received (on any port)."""
    with _media_lock:
        if transfer_id in _media_acks:
            return _media_acks[transfer_id][0]  # return timestamp
    return None


DEVICE_MAP = {
    "/dev/cu.usbmodem101": ("VHF-A", 861805544),
    "/dev/cu.usbmodem1101": ("VHF-B", 861805532),
    "/dev/cu.usbmodem21101": ("BPF-A", 1436471136),
    "/dev/cu.usbmodem21201": ("BPF-B", 1207858088),
}

# TCP connections (more stable than USB serial for multi-device tests)
TCP_DEVICE_MAP = {
    "192.168.1.109": ("VHF-A", 861805544),
    "192.168.1.110": ("VHF-B", 861805532),
    "192.168.1.116": ("BPF-A", 1436471136),
    "192.168.1.113": ("BPF-B", 1207858088),
}

# BLE device names for --ble flag (matched by substring)
BLE_DEVICE_MAP = {
    "T3-S3 V1": 1634999779,
    "XIAO": 1550340734,
    "Pager #1": 2712908800,
    "Pager #2": 2712908928,
}


class Device:
    """Serial-connected Meshtastic device."""
    def __init__(self, port, name, node_num, use_tcp=False):
        self.port = port  # serial port path, TCP address, or BLE address
        self.name = name
        self.node_num = node_num
        self.node_hex = f"!{node_num:08x}"
        self.iface = None
        self.is_ble = False
        self.use_tcp = use_tcp

    def connect(self, retries=3):
        if self.iface:
            return True
        if not self.use_tcp and not os.path.exists(self.port):
            return False
        for attempt in range(retries):
            try:
                if self.use_tcp:
                    self.iface = meshtastic.tcp_interface.TCPInterface(
                        self.port, noNodes=True)
                else:
                    self.iface = meshtastic.serial_interface.SerialInterface(
                        self.port, noNodes=True)
                info = self.iface.getMyNodeInfo()
                actual = info['num']
                if actual != self.node_num:
                    self.node_num = actual
                    self.node_hex = f"!{actual:08x}"
                return True
            except Exception as e:
                if self.iface:
                    try:
                        self.iface.close()
                    except Exception:
                        pass
                    self.iface = None
                if attempt < retries - 1:
                    log(f"  {Colors.Y}Connect {self.name} attempt {attempt + 1} failed, retrying...{Colors.X}")
                    time.sleep(5)
                else:
                    log(f"  {Colors.R}Connect {self.name} failed after {retries} attempts: {e}{Colors.X}")
        return False

    def disconnect(self):
        if self.iface:
            try:
                self.iface.close()
            except Exception:
                pass
            self.iface = None

    def is_alive(self):
        if not self.iface:
            return False
        try:
            # Check if the reader thread is still running
            rx = getattr(self.iface, '_rxThread', None)
            if rx is None or not rx.is_alive():
                return False
            return True
        except Exception:
            return False

    def ensure_connected(self):
        """Ensure interface is connected, reconnect if needed. Returns True if ready."""
        if self.is_alive():
            return True
        log(f"  {Colors.Y}{self.name} connection lost, reconnecting...{Colors.X}")
        self.disconnect()
        time.sleep(2)
        if self.connect():
            log(f"  {Colors.G}{self.name} reconnected{Colors.X}")
            time.sleep(2)
            return True
        log(f"  {Colors.R}{self.name} reconnect failed{Colors.X}")
        return False

    def _safe_send(self, fn, *args, **kwargs):
        """Try to send, reconnect once and retry on failure. Uses global lock."""
        with _send_lock:
            try:
                result = fn(*args, **kwargs)
                time.sleep(_SEND_COOLDOWN)
                return result
            except Exception:
                if self.ensure_connected():
                    result = fn(*args, **kwargs)
                    time.sleep(_SEND_COOLDOWN)
                    return result
                raise

    def send_dm(self, dest_num, text):
        self._safe_send(lambda: self.iface.sendText(
            text, destinationId=dest_num, channelIndex=0))

    def send_dm_ack(self, dest_num, text):
        self._safe_send(lambda: self.iface.sendText(
            text, destinationId=dest_num, channelIndex=0, wantAck=True))

    def send_data(self, dest_num, payload, portnum=256):
        self._safe_send(lambda: self.iface.sendData(
            payload, destinationId=dest_num, portNum=portnum,
            channelIndex=0, wantAck=True))

    def send_media_packet(self, dest_num, protobuf_data):
        self._safe_send(lambda: self.iface.sendData(
            protobuf_data, destinationId=dest_num,
            portNum=MEDIA_TRANSFER_PORT, channelIndex=0, wantAck=False))

    def send_channel(self, text):
        self._safe_send(lambda: self.iface.sendText(text, channelIndex=0))


class BLEDevice(Device):
    """BLE-connected Meshtastic device."""
    def __init__(self, name, node_num):
        super().__init__(f"ble:{name}", name, node_num)
        self.is_ble = True
        self._ble_name = name

    def connect(self, retries=3):
        if not HAS_BLE:
            log(f"  {Colors.R}BLE not available (install bleak){Colors.X}")
            return False
        if self.iface:
            return True
        for attempt in range(retries):
            try:
                log(f"  {Colors.C}Scanning for BLE device '{self._ble_name}'...{Colors.X}")
                self.iface = BLEInterface(self._ble_name, noNodes=True)
                info = self.iface.getMyNodeInfo()
                actual = info['num']
                if actual != self.node_num:
                    self.node_num = actual
                    self.node_hex = f"!{actual:08x}"
                # Update port to use the BLE address for receive matching
                self.port = _get_iface_id(self.iface) or self.port
                return True
            except Exception as e:
                if self.iface:
                    try:
                        self.iface.close()
                    except Exception:
                        pass
                    self.iface = None
                if attempt < retries - 1:
                    log(f"  {Colors.Y}BLE connect {self._ble_name} attempt {attempt + 1} failed, retrying...{Colors.X}")
                    time.sleep(5)
                else:
                    log(f"  {Colors.R}BLE connect {self._ble_name} failed after {retries} attempts: {e}{Colors.X}")
        return False


class MarathonRunner:
    def __init__(self, ports, duration_hours=8, inter_test_delay=1, ble_devices=None,
                 use_tcp=False):
        self.ports = ports
        self.duration_hours = duration_hours
        self.inter_test_delay = inter_test_delay
        self.stats = defaultdict(
            lambda: {"sent": 0, "delivered": 0, "failed": 0, "latencies": []})
        self.total_sent = 0
        self.total_delivered = 0
        self.total_failed = 0
        self.round_num = 0
        self.start_time = None
        self.devices = []
        device_map = TCP_DEVICE_MAP if use_tcp else DEVICE_MAP
        for port in ports:
            if port in device_map:
                name, num = device_map[port]
            else:
                name = f"Dev_{port.split('/')[-1] if '/' in port else port}"
                num = 0
            self.devices.append(Device(port, name, num, use_tcp=use_tcp))
        # Add BLE devices
        for ble_name in (ble_devices or []):
            node_num = BLE_DEVICE_MAP.get(ble_name, 0)
            self.devices.append(BLEDevice(ble_name, node_num))

    def connect_all(self):
        """Connect all devices with staggered delays."""
        connected = []
        for d in self.devices:
            log(f"  Connecting {d.name} on {d.port}...")
            if d.connect():
                log(f"  {Colors.G}{d.name}: {d.node_hex}{Colors.X}")
                connected.append(d)
            else:
                log(f"  {Colors.R}{d.name}: FAILED{Colors.X}")
            time.sleep(3)
        return connected

    def reconnect_if_needed(self, dev):
        """Reconnect a device if its serial connection dropped."""
        return dev.ensure_connected()

    def test_dm(self, sender, receiver):
        """Send a DM and verify delivery."""
        msg_nonce = nonce()
        text = f"MR_{msg_nonce}_DM"
        pair_key = f"{sender.name} → {receiver.name}"
        self.stats[pair_key]["sent"] += 1
        self.total_sent += 1

        try:
            sender.send_dm(receiver.node_num, text)
        except Exception as e:
            log(f"  {Colors.R}SEND ERROR {pair_key}: {e}{Colors.X}")
            self.stats[pair_key]["failed"] += 1
            self.total_failed += 1
            return False

        start = time.time()
        while time.time() - start < 15:
            rx_time = check_received(text, receiver.port)
            if rx_time:
                latency = rx_time - start
                self.stats[pair_key]["delivered"] += 1
                self.stats[pair_key]["latencies"].append(latency)
                self.total_delivered += 1
                return True
            time.sleep(0.3)

        self.stats[pair_key]["failed"] += 1
        self.total_failed += 1
        return False

    def test_dm_ack(self, sender, receiver):
        """Send a DM with wantAck and verify delivery."""
        msg_nonce = nonce()
        text = f"MR_{msg_nonce}_ACK"
        pair_key = f"{sender.name} →ack→ {receiver.name}"
        self.stats[pair_key]["sent"] += 1
        self.total_sent += 1

        try:
            sender.send_dm_ack(receiver.node_num, text)
        except Exception as e:
            log(f"  {Colors.R}ACK SEND ERROR {pair_key}: {e}{Colors.X}")
            self.stats[pair_key]["failed"] += 1
            self.total_failed += 1
            return False

        start = time.time()
        while time.time() - start < 15:
            rx_time = check_received(text, receiver.port)
            if rx_time:
                latency = rx_time - start
                self.stats[pair_key]["delivered"] += 1
                self.stats[pair_key]["latencies"].append(latency)
                self.total_delivered += 1
                return True
            time.sleep(0.3)

        self.stats[pair_key]["failed"] += 1
        self.total_failed += 1
        return False

    def test_data(self, sender, receiver):
        """Send binary data DM (simulates voice/image payload) and verify delivery."""
        msg_nonce = nonce()
        marker = f"MR_{msg_nonce}_BIN"
        # Build a ~100 byte payload with marker + random data
        payload = marker.encode() + b'\x00' + os.urandom(80)
        pair_key = f"{sender.name} →bin→ {receiver.name}"
        self.stats[pair_key]["sent"] += 1
        self.total_sent += 1

        try:
            sender.send_data(receiver.node_num, payload)
        except Exception as e:
            log(f"  {Colors.R}BIN SEND ERROR {pair_key}: {e}{Colors.X}")
            self.stats[pair_key]["failed"] += 1
            self.total_failed += 1
            return False

        start = time.time()
        while time.time() - start < 15:
            rx_time = check_received(marker, receiver.port)
            if rx_time:
                latency = rx_time - start
                self.stats[pair_key]["delivered"] += 1
                self.stats[pair_key]["latencies"].append(latency)
                self.total_delivered += 1
                return True
            time.sleep(0.3)

        self.stats[pair_key]["failed"] += 1
        self.total_failed += 1
        return False

    def test_media_transfer(self, sender, receiver, content_type, label,
                             payload=None, payload_size=0, width=0, height=0,
                             duration_seconds=0):
        """Send a multi-chunk media transfer and verify ACK_COMPLETE.

        content_type: CT_VOICE_MEMO (0) or CT_IMAGE_THUMBNAIL (1)
        label: display label (e.g. 'VMO' or 'IMG')
        payload: actual bytes to send (real Codec2/JPEG data)
        """
        pair_key = f"{sender.name} →{label.lower()}→ {receiver.name}"
        self.stats[pair_key]["sent"] += 1
        self.total_sent += 1

        if payload is None:
            payload = os.urandom(payload_size if payload_size else 800)
        payload_size = len(payload)
        transfer_id = random.randint(1, 0x7FFFFFFF)
        crc = zlib.crc32(payload) & 0xFFFFFFFF
        chunk_size = 200
        total_chunks = (payload_size + chunk_size - 1) // chunk_size

        try:
            # 1. Send MEDIA_START
            start_pkt = encode_media_transfer(
                msg_type=MT_START, transfer_id=transfer_id,
                total_chunks=total_chunks, total_size=payload_size,
                content_type=content_type, checksum=crc,
                duration_seconds=duration_seconds,
                width=width, height=height)
            sender.send_media_packet(receiver.node_num, start_pkt)
            time.sleep(3)

            # 2. Send MEDIA_CHUNKs (pace at LoRa speed: ~2s/packet)
            for i in range(total_chunks):
                chunk = payload[i * chunk_size:(i + 1) * chunk_size]
                chunk_pkt = encode_media_transfer(
                    msg_type=MT_CHUNK, transfer_id=transfer_id,
                    chunk_index=i, chunk_data=chunk)
                sender.send_media_packet(receiver.node_num, chunk_pkt)
                time.sleep(3)

            # 3. Send MEDIA_COMPLETE
            complete_pkt = encode_media_transfer(
                msg_type=MT_COMPLETE, transfer_id=transfer_id, checksum=crc)
            sender.send_media_packet(receiver.node_num, complete_pkt)

        except Exception as e:
            log(f"  {Colors.R}{label} SEND ERROR {pair_key}: {e}{Colors.X}")
            self.stats[pair_key]["failed"] += 1
            self.total_failed += 1
            return False

        # 4. Wait for MEDIA_ACK_COMPLETE
        start = time.time()
        timeout = 60
        while time.time() - start < timeout:
            ack_time = check_media_ack(transfer_id)
            if ack_time:
                latency = ack_time - start
                self.stats[pair_key]["delivered"] += 1
                self.stats[pair_key]["latencies"].append(latency)
                self.total_delivered += 1
                return True
            time.sleep(0.3)

        self.stats[pair_key]["failed"] += 1
        self.total_failed += 1
        return False

    def test_voice_memo(self, sender, receiver):
        """Send a real Codec2 voice memo (~525 bytes, 3 chunks) and verify delivery."""
        payload = get_voice_memo_payload()
        return self.test_media_transfer(
            sender, receiver, CT_VOICE_MEMO, "VMO",
            payload=payload, duration_seconds=3)

    def test_image(self, sender, receiver):
        """Send a real JPEG thumbnail (~800-1200 bytes) and verify delivery."""
        payload = get_image_payload()
        return self.test_media_transfer(
            sender, receiver, CT_IMAGE_THUMBNAIL, "IMG",
            payload=payload, width=80, height=60)

    def test_channel(self, sender, receivers):
        """Send a channel broadcast and verify receipt on all receivers."""
        msg_nonce = nonce()
        text = f"MR_{msg_nonce}_CH"
        results = {}

        for r in receivers:
            pair_key = f"{sender.name} →ch→ {r.name}"
            self.stats[pair_key]["sent"] += 1
            self.total_sent += 1

        try:
            sender.send_channel(text)
        except Exception as e:
            log(f"  {Colors.R}CH SEND ERROR from {sender.name}: {e}{Colors.X}")
            for r in receivers:
                pair_key = f"{sender.name} →ch→ {r.name}"
                self.stats[pair_key]["failed"] += 1
                self.total_failed += 1
            return {}

        start = time.time()
        pending = set(r.port for r in receivers)
        while time.time() - start < 30 and pending:
            for r in receivers:
                if r.port not in pending:
                    continue
                rx_time = check_received(text, r.port)
                if rx_time:
                    latency = rx_time - start
                    pair_key = f"{sender.name} →ch→ {r.name}"
                    self.stats[pair_key]["delivered"] += 1
                    self.stats[pair_key]["latencies"].append(latency)
                    self.total_delivered += 1
                    results[r.name] = latency
                    pending.discard(r.port)
            time.sleep(0.3)

        for r in receivers:
            if r.port in pending:
                pair_key = f"{sender.name} →ch→ {r.name}"
                self.stats[pair_key]["failed"] += 1
                self.total_failed += 1
                results[r.name] = None

        return results

    def run_round(self, connected):
        self.round_num += 1

        if len(connected) < 2:
            log(f"{Colors.R}Less than 2 devices connected, waiting...{Colors.X}")
            time.sleep(30)
            return connected

        log(f"\n{Colors.B}═══ Round {self.round_num} ({len(connected)} devices) ═══{Colors.X}")

        # Check connections are alive
        alive = []
        for d in connected:
            if self.reconnect_if_needed(d):
                alive.append(d)
        connected = alive

        if len(connected) < 2:
            log(f"{Colors.R}Less than 2 alive devices{Colors.X}")
            return connected

        # Generate all ordered pairs for DM tests
        pairs = [(a, b) for a in connected for b in connected if a != b]
        random.shuffle(pairs)

        round_passed = 0
        round_total = 0

        # Text DM tests
        for sender, receiver in pairs:
            ok = self.test_dm(sender, receiver)
            round_total += 1
            if ok:
                round_passed += 1
                pair_key = f"{sender.name} → {receiver.name}"
                lat = self.stats[pair_key]["latencies"][-1]
                log(f"  DM {Colors.G}✓{Colors.X} {sender.name:12s} → {receiver.name:12s} ({lat:.1f}s)")
            else:
                log(f"  DM {Colors.R}✗{Colors.X} {sender.name:12s} → {receiver.name:12s}")
            time.sleep(self.inter_test_delay)

        # Acknowledged DM tests (wantAck=True)
        ack_pair = random.choice(pairs) if pairs else None
        if ack_pair:
            sender, receiver = ack_pair
            ok = self.test_dm_ack(sender, receiver)
            round_total += 1
            if ok:
                round_passed += 1
                pair_key = f"{sender.name} →ack→ {receiver.name}"
                lat = self.stats[pair_key]["latencies"][-1]
                log(f"  ACK{Colors.G}✓{Colors.X} {sender.name:12s} →ack→ {receiver.name:12s} ({lat:.1f}s)")
            else:
                log(f"  ACK{Colors.R}✗{Colors.X} {sender.name:12s} →ack→ {receiver.name:12s}")
            time.sleep(self.inter_test_delay)

        # Binary data DM tests (simulates voice/image payload)
        bin_pair = random.choice(pairs) if pairs else None
        if bin_pair:
            sender, receiver = bin_pair
            ok = self.test_data(sender, receiver)
            round_total += 1
            if ok:
                round_passed += 1
                pair_key = f"{sender.name} →bin→ {receiver.name}"
                lat = self.stats[pair_key]["latencies"][-1]
                log(f"  BIN{Colors.G}✓{Colors.X} {sender.name:12s} →bin→ {receiver.name:12s} ({lat:.1f}s)")
            else:
                log(f"  BIN{Colors.R}✗{Colors.X} {sender.name:12s} →bin→ {receiver.name:12s}")
            time.sleep(self.inter_test_delay)

        # Voice memo transfer test (multi-chunk, ~800 bytes)
        vmo_pair = random.choice(pairs) if pairs else None
        if vmo_pair:
            sender, receiver = vmo_pair
            ok = self.test_voice_memo(sender, receiver)
            round_total += 1
            if ok:
                round_passed += 1
                pair_key = f"{sender.name} →vmo→ {receiver.name}"
                lat = self.stats[pair_key]["latencies"][-1]
                log(f"  VMO{Colors.G}✓{Colors.X} {sender.name:12s} →vmo→ {receiver.name:12s} ({lat:.1f}s)")
            else:
                log(f"  VMO{Colors.R}✗{Colors.X} {sender.name:12s} →vmo→ {receiver.name:12s}")
            time.sleep(self.inter_test_delay)

        # Image transfer test (multi-chunk, ~5000 bytes) — every 3rd round
        if self.round_num % 3 == 0:
            img_pair = random.choice(pairs) if pairs else None
            if img_pair:
                sender, receiver = img_pair
                ok = self.test_image(sender, receiver)
                round_total += 1
                if ok:
                    round_passed += 1
                    pair_key = f"{sender.name} →img→ {receiver.name}"
                    lat = self.stats[pair_key]["latencies"][-1]
                    log(f"  IMG{Colors.G}✓{Colors.X} {sender.name:12s} →img→ {receiver.name:12s} ({lat:.1f}s)")
                else:
                    log(f"  IMG{Colors.R}✗{Colors.X} {sender.name:12s} →img→ {receiver.name:12s}")
                time.sleep(self.inter_test_delay)

        # Channel tests — each device broadcasts, others verify receipt
        for sender in connected:
            receivers = [d for d in connected if d != sender]
            results = self.test_channel(sender, receivers)
            for r_name, lat in results.items():
                round_total += 1
                if lat is not None:
                    round_passed += 1
                    log(f"  CH {Colors.G}✓{Colors.X} {sender.name:12s} →ch→ {r_name:12s} ({lat:.1f}s)")
                else:
                    log(f"  CH {Colors.R}✗{Colors.X} {sender.name:12s} →ch→ {r_name:12s}")
            time.sleep(self.inter_test_delay)

        rate = (self.total_delivered / self.total_sent * 100) if self.total_sent else 0
        elapsed = (time.time() - self.start_time) / 60
        log(f"\n  Round {self.round_num}: {round_passed}/{round_total} | "
            f"Overall: {self.total_delivered}/{self.total_sent} ({rate:.1f}%) | "
            f"Elapsed: {elapsed:.0f}m")

        return connected

    def print_stats(self):
        elapsed = (time.time() - self.start_time) / 60
        rate = (self.total_delivered / self.total_sent * 100) if self.total_sent else 0

        log(f"\n{Colors.B}{'═' * 80}{Colors.X}")
        log(f"{Colors.B}MARATHON STATS — {self.round_num} rounds, "
            f"{elapsed:.0f} min{Colors.X}")
        log(f"{Colors.B}{'═' * 80}{Colors.X}")
        log(f"Total: {self.total_sent} sent, {self.total_delivered} delivered, "
            f"{self.total_failed} failed ({rate:.1f}%)")
        log(f"\n{'Pair':36s} | {'Sent':>5s} | {'OK':>5s} | {'Fail':>5s} | "
            f"{'Rate':>6s} | {'Avg Lat':>8s}")
        log("-" * 80)

        for key in sorted(self.stats.keys()):
            s = self.stats[key]
            r = (s["delivered"] / s["sent"] * 100) if s["sent"] else 0
            lat = sum(s["latencies"]) / len(s["latencies"]) if s["latencies"] else 0
            c = Colors.G if r >= 95 else (Colors.Y if r >= 80 else Colors.R)
            log(f"{key:36s} | {s['sent']:5d} | {s['delivered']:5d} | "
                f"{s['failed']:5d} | {c}{r:5.1f}%{Colors.X} | {lat:7.1f}s")

        log(f"{'═' * 80}\n")

    def run(self):
        self.start_time = time.time()
        end_time = self.start_time + (self.duration_hours * 3600)

        log(f"{Colors.B}Starting {self.duration_hours}-hour marathon "
            f"with {len(self.devices)} devices (persistent connections){Colors.X}")
        log(f"Inter-test delay: {self.inter_test_delay}s")
        log(f"End time: {time.strftime('%H:%M:%S', time.localtime(end_time))}")

        # Connect all devices once
        connected = self.connect_all()
        if len(connected) < 2:
            log(f"{Colors.R}Need at least 2 devices!{Colors.X}")
            return

        # Print device table
        log(f"\n{'Device':12s} | {'Type':5s} | {'Port':28s} | {'Node':12s}")
        log("-" * 66)
        for d in connected:
            conn_type = "BLE" if d.is_ble else "SER"
            log(f"{d.name:12s} | {conn_type:5s} | {d.port:28s} | {d.node_hex:12s}")
        log("")

        # Warmup
        log("Warming up for 3s...")
        time.sleep(3)

        try:
            while time.time() < end_time:
                connected = self.run_round(connected)
                if self.round_num % 5 == 0:
                    self.print_stats()
        except KeyboardInterrupt:
            log(f"\n{Colors.Y}Interrupted.{Colors.X}")
        except Exception as e:
            log(f"\n{Colors.R}Error: {e}{Colors.X}")
            traceback.print_exc()
        finally:
            self.print_stats()
            for d in self.devices:
                d.disconnect()


def main():
    parser = argparse.ArgumentParser(
        description="MeshReliable Marathon — Multi-Device Deliverability Test",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  %(prog)s                              # auto-detect, 8h, 1s delay
  %(prog)s --duration 2 --delay 2       # 2-hour marathon, 2s delay
  %(prog)s --ble "T3-S3 V1"            # include BLE device
  %(prog)s --ports /dev/cu.usbmodem101  # specific serial port""")
    parser.add_argument("--duration", type=float, default=8,
                        help="Marathon duration in hours (default: 8)")
    parser.add_argument("--delay", type=float, default=1,
                        help="Seconds between tests (default: 1)")
    parser.add_argument("--ports", type=str, default=None,
                        help="Comma-separated serial ports or TCP addresses")
    parser.add_argument("--ble", type=str, action="append", default=None,
                        help="BLE device name to connect (can specify multiple)")
    parser.add_argument("--tcp", action="store_true", default=False,
                        help="Use TCP connections instead of serial (more stable for multi-device)")
    args = parser.parse_args()

    use_tcp = args.tcp

    if args.ports:
        ports = [p.strip() for p in args.ports.split(",")]
    elif use_tcp:
        ports = list(TCP_DEVICE_MAP.keys())
        log(f"Using TCP connections to {len(ports)} devices")
    else:
        ports = [p for p in DEVICE_MAP if os.path.exists(p)]
        if not ports and not args.ble:
            log(f"{Colors.R}No devices found!{Colors.X}")
            sys.exit(1)
        if ports:
            log(f"Auto-detected {len(ports)} serial ports")

    runner = MarathonRunner(ports, args.duration, args.delay, ble_devices=args.ble,
                            use_tcp=use_tcp)
    runner.run()


if __name__ == "__main__":
    main()
