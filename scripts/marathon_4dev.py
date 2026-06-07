#!/usr/bin/env python3
"""
MeshReliable Marathon — 4-Device Rotational Test (1000+ messages).

Uses 2 serial connections at a time and rotates through all device pairs
to avoid USB-JTAG contention with 4 simultaneous ESP32-S3 connections.

Also monitors MQTT broker for message delivery verification.

Test types per pair:
  - DM: Text direct message (each direction)
  - ACK: Text DM with wantAck
  - BIN: Binary data DM
  - VMO: Voice memo via MediaTransfer (Codec2)
  - IMG: Image via MediaTransfer (JPEG thumbnail)
  - CH: Channel broadcast (sender → all via MQTT downlink)
"""

import argparse
import os
import random
import signal
import string
import struct
import subprocess
import sys
import threading
import time
import traceback
import zlib
from collections import defaultdict
from itertools import combinations

try:
    import meshtastic
    import meshtastic.serial_interface
    from pubsub import pub
except ImportError:
    print("ERROR: pip install meshtastic")
    sys.exit(1)

try:
    import numpy as np
    import pycodec2
    HAS_CODEC2 = True
except ImportError:
    HAS_CODEC2 = False

try:
    from PIL import Image
    import io
    HAS_PILLOW = True
except ImportError:
    HAS_PILLOW = False

# ---------- Device config ----------
DEVICES = [
    {"port": "/dev/cu.usbmodem101",   "name": "VHF-A", "num": 861805544},
    {"port": "/dev/cu.usbmodem1101",  "name": "VHF-B", "num": 861805532},
    {"port": "/dev/cu.usbmodem21101", "name": "BPF-A", "num": 1436471136},
    {"port": "/dev/cu.usbmodem21201", "name": "BPF-B", "num": 1207858088},
]

# MQTT broker for monitoring
MQTT_HOST = "home.yazdikann.com"
MQTT_PORT = 1883
MQTT_USER = "admin"
MQTT_PASS = "admin"

# ---------- Protobuf encoding ----------
MT_CHUNK = 0; MT_START = 1; MT_COMPLETE = 2; MT_ACK_COMPLETE = 4
CT_VOICE_MEMO = 0; CT_IMAGE_THUMBNAIL = 1
MEDIA_PORT = 259


def _varint(v):
    r = bytearray()
    while v > 0x7F:
        r.append((v & 0x7F) | 0x80)
        v >>= 7
    r.append(v & 0x7F)
    return bytes(r)


def _fv(fn, v):
    return (_varint((fn << 3) | 0) + _varint(v)) if v else b''


def _fb(fn, d):
    return (_varint((fn << 3) | 2) + _varint(len(d)) + d) if d else b''


def encode_mt(msg_type, tid, ci=0, tc=0, ts_=0, cd=b'', ct=0, ck=0, dur=0, w=0, h=0):
    return (b'' + _fv(1, msg_type) + _fv(2, tid) + _fv(3, ci) + _fv(4, tc)
            + _fv(5, ts_) + _fb(6, cd) + _fv(7, ct) + _fv(9, ck)
            + _fv(11, dur) + _fv(12, w) + _fv(13, h))


def decode_mt_header(data):
    pos = 0; mt = 0; tid = 0
    while pos < len(data):
        fn = data[pos] >> 3; wt = data[pos] & 7; pos += 1
        if wt == 0:
            v = 0; s = 0
            while pos < len(data):
                b = data[pos]; pos += 1; v |= (b & 0x7F) << s
                if not (b & 0x80): break
                s += 7
            if fn == 1: mt = v
            elif fn == 2: return mt, v
        elif wt == 2:
            l = 0; s = 0
            while pos < len(data):
                b = data[pos]; pos += 1; l |= (b & 0x7F) << s
                if not (b & 0x80): break
                s += 7
            pos += l
        else:
            break
    return mt, tid


def gen_codec2(dur=3, freq=440):
    if not HAS_CODEC2:
        return os.urandom(int(dur * 8000 / 320) * 7)
    c2 = pycodec2.Codec2(1300)
    spf = c2.samples_per_frame()
    total = int(8000 * dur)
    t = np.arange(total, dtype=np.float32)
    s = (np.sin(2 * np.pi * freq * t / 8000) * 16000).astype(np.int16)
    frames = [bytes(c2.encode(s[i:i + spf])) for i in range(0, total - spf + 1, spf)]
    return b''.join(frames)


def gen_jpeg(w=80, h=60):
    if not HAS_PILLOW:
        return os.urandom(800)
    img = Image.new('RGB', (w, h))
    px = img.load()
    ro, go = random.randint(0, 255), random.randint(0, 255)
    for y in range(h):
        for x in range(w):
            px[x, y] = ((x * 255 // w + ro) % 256, (y * 255 // h + go) % 256,
                         ((x + y) * 255 // (w + h)) % 256)
    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=30)
    return buf.getvalue()


# ---------- Colors and logging ----------
class C:
    G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; B = "\033[1m"; X = "\033[0m"


def ts():
    return time.strftime("%H:%M:%S")


def log(msg):
    print(f"[{ts()}] {msg}", flush=True)


def nonce(n=6):
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=n))


# ---------- RX tracking ----------
_received = {}
_rx_lock = threading.Lock()
_media_acks = {}
_media_lock = threading.Lock()


def _on_receive(packet, interface=None):
    try:
        d = packet.get('decoded', {})
        pn = d.get('portnum', '')
        port = getattr(interface, 'devPath', None) or id(interface)
        key = None
        if pn == 'TEXT_MESSAGE_APP':
            t = d.get('text', '')
            if t and t.startswith('MR_'):
                key = t
        elif pn == 'PRIVATE_APP':
            p = d.get('payload', b'')
            if isinstance(p, bytes) and p.startswith(b'MR_'):
                key = p.split(b'\x00')[0].decode('utf-8', errors='ignore')
        elif str(pn) in ('MEDIA_TRANSFER_APP', '259'):
            p = d.get('payload', b'')
            if isinstance(p, bytes) and len(p) >= 2:
                mt, tid = decode_mt_header(p)
                if mt == MT_ACK_COMPLETE and tid and port:
                    with _media_lock:
                        _media_acks[tid] = (time.time(), port)
        if key and port:
            with _rx_lock:
                _received.setdefault(key, [])
                if not any(p == port for _, p in _received[key]):
                    _received[key].append((time.time(), port))
    except Exception:
        pass


pub.subscribe(_on_receive, "meshtastic.receive")


def check_rx(text, port, timeout=5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        with _rx_lock:
            for t, p in _received.get(text, []):
                if p == port:
                    return t
        time.sleep(0.2)
    return None


def check_media_ack(tid, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        with _media_lock:
            if tid in _media_acks:
                return _media_acks[tid][0]
        time.sleep(0.3)
    return None


# ---------- MQTT counter ----------
_mqtt_count = 0
_mqtt_lock = threading.Lock()


def mqtt_monitor():
    """Background thread counting MQTT messages."""
    global _mqtt_count
    try:
        proc = subprocess.Popen(
            ["mosquitto_sub", "-h", MQTT_HOST, "-p", str(MQTT_PORT),
             "-u", MQTT_USER, "-P", MQTT_PASS, "-t", "msh/US/2/e/+/+", "-v"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        while True:
            line = proc.stdout.readline()
            if not line:
                break
            with _mqtt_lock:
                _mqtt_count += 1
    except Exception:
        pass


def get_mqtt_count():
    with _mqtt_lock:
        return _mqtt_count


# ---------- Pair-based test runner ----------
class PairRunner:
    def __init__(self, duration_hours=4, delay=0.5):
        self.duration = duration_hours
        self.delay = delay
        self.stats = defaultdict(lambda: {"sent": 0, "ok": 0, "fail": 0, "lat": []})
        self.total_sent = 0
        self.total_ok = 0
        self.total_fail = 0
        self.round_num = 0
        self.start_time = None
        # Pre-gen payloads
        self._codec2 = gen_codec2(3, 440)
        # All 6 ordered pairs (A→B, B→A for 4C2=6 combos = 12 directions)
        self.pairs = [(i, j) for i in range(4) for j in range(4) if i != j]

    def _connect_pair(self, idx_a, idx_b):
        """Connect two devices by index, return (iface_a, iface_b) or None."""
        da, db = DEVICES[idx_a], DEVICES[idx_b]
        ia = ib = None
        try:
            ia = meshtastic.serial_interface.SerialInterface(da["port"], noNodes=True)
            time.sleep(0.5)
            ib = meshtastic.serial_interface.SerialInterface(db["port"], noNodes=True)
            time.sleep(0.5)
            return ia, ib
        except Exception as e:
            log(f"  {C.R}Connect failed {da['name']}/{db['name']}: {e}{C.X}")
            self._close(ia, ib)
            return None

    def _close(self, *ifaces):
        for iface in ifaces:
            if iface:
                try:
                    iface.close()
                except Exception:
                    pass
        time.sleep(0.5)

    def _record(self, key, ok, lat=None):
        self.stats[key]["sent"] += 1
        self.total_sent += 1
        if ok:
            self.stats[key]["ok"] += 1
            self.total_ok += 1
            if lat is not None:
                self.stats[key]["lat"].append(lat)
        else:
            self.stats[key]["fail"] += 1
            self.total_fail += 1

    def test_dm(self, ia, ib, da, db):
        """DM from A to B, check receipt on B's serial."""
        n = nonce()
        text = f"MR_{n}_DM"
        key = f"{da['name']} → {db['name']}"
        sent_at = time.time()
        try:
            self._safe_call(lambda: ia.sendText(text, destinationId=db["num"], channelIndex=0), timeout=10)
        except Exception as e:
            log(f"  {C.R}SEND ERR {key}: {e}{C.X}")
            self._record(key, False)
            raise  # propagate to abort round on serial failure
        t = check_rx(text, db["port"])
        ok = t is not None
        lat = (t - sent_at) if t else None
        self._record(key, ok, lat)
        mark = f"{C.G}✓{C.X}" if ok else f"{C.R}✗{C.X}"
        extra = f" ({lat:.1f}s)" if lat else ""
        log(f"  DM {mark} {da['name']:6s}→{db['name']:6s}{extra}")
        return ok

    def test_dm_ack(self, ia, ib, da, db):
        n = nonce()
        text = f"MR_{n}_ACK"
        key = f"{da['name']} →ack→ {db['name']}"
        try:
            self._safe_call(lambda: ia.sendText(text, destinationId=db["num"], channelIndex=0, wantAck=True), timeout=10)
        except Exception as e:
            self._record(key, False)
            raise
        t = check_rx(text, db["port"])
        ok = t is not None
        self._record(key, ok)
        mark = f"{C.G}✓{C.X}" if ok else f"{C.R}✗{C.X}"
        log(f"  ACK{mark} {da['name']:6s}→{db['name']:6s}")
        return ok

    def test_bin(self, ia, ib, da, db):
        n = nonce()
        marker = f"MR_{n}_BIN"
        payload = marker.encode() + b'\x00' + os.urandom(80)
        key = f"{da['name']} →bin→ {db['name']}"
        try:
            self._safe_call(lambda: ia.sendData(payload, destinationId=db["num"], portNum=256,
                        channelIndex=0, wantAck=True), timeout=10)
        except Exception as e:
            self._record(key, False)
            raise
        t = check_rx(marker, db["port"])
        ok = t is not None
        self._record(key, ok)
        mark = f"{C.G}✓{C.X}" if ok else f"{C.R}✗{C.X}"
        log(f"  BIN{mark} {da['name']:6s}→{db['name']:6s}")
        return ok

    def test_channel(self, ia, ib, da, db):
        """Channel broadcast from A, check on B."""
        n = nonce()
        text = f"MR_{n}_CH"
        key = f"{da['name']} →ch→ {db['name']}"
        try:
            self._safe_call(lambda: ia.sendText(text, channelIndex=0), timeout=10)
        except Exception as e:
            self._record(key, False)
            raise
        t = check_rx(text, db["port"], timeout=8)
        ok = t is not None
        self._record(key, ok)
        mark = f"{C.G}✓{C.X}" if ok else f"{C.R}✗{C.X}"
        log(f"  CH {mark} {da['name']:6s}→{db['name']:6s}")
        return ok

    def test_voice_memo(self, ia, ib, da, db):
        key = f"{da['name']} →vmo→ {db['name']}"
        payload = self._codec2
        tid = random.randint(1, 0x7FFFFFFF)
        crc = zlib.crc32(payload) & 0xFFFFFFFF
        cs = 200
        tc = (len(payload) + cs - 1) // cs
        try:
            self._safe_call(lambda: ia.sendData(
                encode_mt(MT_START, tid, tc=tc, ts_=len(payload),
                          ct=CT_VOICE_MEMO, ck=crc, dur=3),
                destinationId=db["num"], portNum=MEDIA_PORT, channelIndex=0, wantAck=False), timeout=10)
            time.sleep(2.0)
            for i in range(tc):
                chunk = payload[i * cs:(i + 1) * cs]
                self._safe_call(lambda ci=i, ch=chunk: ia.sendData(
                    encode_mt(MT_CHUNK, tid, ci=ci, cd=ch),
                    destinationId=db["num"], portNum=MEDIA_PORT, channelIndex=0, wantAck=False), timeout=10)
                time.sleep(2.0)
            self._safe_call(lambda: ia.sendData(
                encode_mt(MT_COMPLETE, tid, ck=crc),
                destinationId=db["num"], portNum=MEDIA_PORT, channelIndex=0, wantAck=False), timeout=10)
        except Exception as e:
            log(f"  {C.R}VMO SEND ERR: {e}{C.X}")
            self._record(key, False)
            raise
        t = check_media_ack(tid, timeout=45)
        ok = t is not None
        self._record(key, ok)
        mark = f"{C.G}✓{C.X}" if ok else f"{C.R}✗{C.X}"
        log(f"  VMO{mark} {da['name']:6s}→{db['name']:6s} ({tc} chunks)")
        return ok

    def test_image(self, ia, ib, da, db):
        key = f"{da['name']} →img→ {db['name']}"
        payload = gen_jpeg()
        tid = random.randint(1, 0x7FFFFFFF)
        crc = zlib.crc32(payload) & 0xFFFFFFFF
        cs = 200
        tc = (len(payload) + cs - 1) // cs
        try:
            self._safe_call(lambda: ia.sendData(
                encode_mt(MT_START, tid, tc=tc, ts_=len(payload),
                          ct=CT_IMAGE_THUMBNAIL, ck=crc, w=80, h=60),
                destinationId=db["num"], portNum=MEDIA_PORT, channelIndex=0, wantAck=False), timeout=10)
            time.sleep(2.0)
            for i in range(tc):
                chunk = payload[i * cs:(i + 1) * cs]
                self._safe_call(lambda ci=i, ch=chunk: ia.sendData(
                    encode_mt(MT_CHUNK, tid, ci=ci, cd=ch),
                    destinationId=db["num"], portNum=MEDIA_PORT, channelIndex=0, wantAck=False), timeout=10)
                time.sleep(2.0)
            self._safe_call(lambda: ia.sendData(
                encode_mt(MT_COMPLETE, tid, ck=crc),
                destinationId=db["num"], portNum=MEDIA_PORT, channelIndex=0, wantAck=False), timeout=10)
        except Exception as e:
            log(f"  {C.R}IMG SEND ERR: {e}{C.X}")
            self._record(key, False)
            raise
        t = check_media_ack(tid, timeout=90)
        ok = t is not None
        self._record(key, ok)
        mark = f"{C.G}✓{C.X}" if ok else f"{C.R}✗{C.X}"
        log(f"  IMG{mark} {da['name']:6s}→{db['name']:6s} ({tc} chunks, {len(payload)}B)")
        return ok

    def _safe_call(self, fn, timeout=30):
        """Run fn in a thread with a timeout to prevent hangs."""
        result = [None]
        exc = [None]
        def wrapper():
            try:
                result[0] = fn()
            except Exception as e:
                exc[0] = e
        t = threading.Thread(target=wrapper, daemon=True)
        t.start()
        t.join(timeout)
        if t.is_alive():
            raise TimeoutError(f"Operation timed out after {timeout}s")
        if exc[0]:
            raise exc[0]
        return result[0]

    def run_pair_round(self, idx_a, idx_b, do_media=False, do_image=False):
        """Run one round between a pair of devices."""
        da, db = DEVICES[idx_a], DEVICES[idx_b]
        try:
            conn = self._safe_call(lambda: self._connect_pair(idx_a, idx_b), timeout=15)
        except TimeoutError:
            log(f"  {C.R}Connect timeout {da['name']}/{db['name']}{C.X}")
            conn = None
        if not conn:
            for key in [f"{da['name']} → {db['name']}", f"{db['name']} → {da['name']}",
                        f"{da['name']} →ch→ {db['name']}"]:
                self._record(key, False)
            return
        ia, ib = conn

        try:
            # Multiple DMs both directions for throughput
            for _ in range(3):
                self.test_dm(ia, ib, da, db)
                time.sleep(self.delay)
                self.test_dm(ib, ia, db, da)
                time.sleep(self.delay)

            # ACK test
            self.test_dm_ack(ia, ib, da, db)
            time.sleep(self.delay)

            # Binary data test
            self.test_bin(ia, ib, da, db)
            time.sleep(self.delay)

            # Channel broadcast from A, check on B
            self.test_channel(ia, ib, da, db)
            time.sleep(self.delay)

            # Voice memo
            if do_media:
                s, r = (ia, da), (ib, db)
                if random.random() < 0.5:
                    s, r = (ib, db), (ia, da)
                self.test_voice_memo(s[0], r[0], s[1], r[1])
                time.sleep(self.delay)

            # Image
            if do_image:
                s, r = (ia, da), (ib, db)
                if random.random() < 0.5:
                    s, r = (ib, db), (ia, da)
                self.test_image(s[0], r[0], s[1], r[1])
                time.sleep(self.delay)

        except Exception as e:
            log(f"  {C.R}Round error: {e}{C.X}")
        finally:
            self._close(ia, ib)

    def print_stats(self):
        elapsed = (time.time() - self.start_time) / 60
        rate = (self.total_ok / self.total_sent * 100) if self.total_sent else 0
        mqtt = get_mqtt_count()

        log(f"\n{C.B}{'═' * 80}{C.X}")
        log(f"{C.B}STATS — {self.round_num} rounds, {elapsed:.0f}m, "
            f"MQTT broker msgs: {mqtt}{C.X}")
        log(f"{C.B}{'═' * 80}{C.X}")
        log(f"Total: {self.total_sent} sent, {self.total_ok} OK, "
            f"{self.total_fail} FAIL ({rate:.1f}%)")
        log(f"\n{'Pair':36s} | {'Sent':>5s} | {'OK':>5s} | {'Fail':>5s} | "
            f"{'Rate':>6s} | {'Avg':>7s}")
        log("-" * 80)

        for key in sorted(self.stats.keys()):
            s = self.stats[key]
            r = (s["ok"] / s["sent"] * 100) if s["sent"] else 0
            lat = sum(s["lat"]) / len(s["lat"]) if s["lat"] else 0
            c = C.G if r >= 95 else (C.Y if r >= 80 else C.R)
            log(f"{key:36s} | {s['sent']:5d} | {s['ok']:5d} | "
                f"{s['fail']:5d} | {c}{r:5.1f}%{C.X} | {lat:6.1f}s")

        log(f"{'═' * 80}\n")

    def run(self):
        self.start_time = time.time()
        end_time = self.start_time + (self.duration * 3600)

        # Start MQTT monitor
        mqtt_thread = threading.Thread(target=mqtt_monitor, daemon=True)
        mqtt_thread.start()

        log(f"{C.B}MeshReliable Marathon — 4 devices, pair rotation{C.X}")
        log(f"Duration: {self.duration}h, delay: {self.delay}s")
        log(f"Devices: {', '.join(d['name'] for d in DEVICES)}")
        log(f"MQTT monitoring: {MQTT_HOST}:{MQTT_PORT}")
        log(f"Codec2: {'real' if HAS_CODEC2 else 'random bytes'}")
        log(f"JPEG: {'real' if HAS_PILLOW else 'random bytes'}")
        log("")

        # Generate pair rotation: 6 unique unordered pairs
        pair_indices = list(combinations(range(4), 2))  # [(0,1),(0,2),(0,3),(1,2),(1,3),(2,3)]

        try:
            while time.time() < end_time:
                self.round_num += 1
                pi = pair_indices[(self.round_num - 1) % len(pair_indices)]
                da, db = DEVICES[pi[0]], DEVICES[pi[1]]

                elapsed = (time.time() - self.start_time) / 60
                remaining = (end_time - time.time()) / 60
                log(f"\n{C.B}═══ Round {self.round_num} ({da['name']} ↔ {db['name']}) "
                    f"[{elapsed:.0f}m / {remaining:.0f}m left] ═══{C.X}")

                do_media = (self.round_num % 3 == 0)  # every 3rd round
                do_image = (self.round_num % 6 == 0)  # every 6th round

                self.run_pair_round(pi[0], pi[1], do_media=do_media, do_image=do_image)

                if self.round_num % 6 == 0:
                    self.print_stats()

        except KeyboardInterrupt:
            log(f"\n{C.Y}Interrupted{C.X}")
        except Exception as e:
            log(f"\n{C.R}Error: {e}{C.X}")
            traceback.print_exc()
        finally:
            self.print_stats()
            log(f"MQTT broker messages seen: {get_mqtt_count()}")


def main():
    parser = argparse.ArgumentParser(description="MeshReliable 4-Device Marathon")
    parser.add_argument("--duration", type=float, default=4, help="Hours (default: 4)")
    parser.add_argument("--delay", type=float, default=0.5, help="Delay between tests (default: 0.5)")
    args = parser.parse_args()

    runner = PairRunner(duration_hours=args.duration, delay=args.delay)
    runner.run()


if __name__ == "__main__":
    main()
