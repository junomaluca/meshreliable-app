# MeshReliable Testing Guide

## Marathon Test Script

`scripts/serial_marathon.py` — automated multi-device deliverability testing over serial and BLE connections.

### What It Tests

Each round runs the following test types across all connected devices:

| Test | Label | Description | Payload |
|------|-------|-------------|---------|
| Text DM | `DM` | Direct message, every device pair | Short text with nonce |
| Ack DM | `ACK` | DM with `wantAck=True`, 1 random pair | Short text with nonce |
| Binary Data | `BIN` | Binary payload on PRIVATE_APP port, 1 pair | 100 bytes with marker |
| Voice Memo | `VMO` | Multi-chunk MediaTransfer, 1 random pair | Real Codec2 Mode 1300 audio (3s 440Hz, ~525 bytes, 3 chunks) |
| Image | `IMG` | Multi-chunk MediaTransfer, every 3rd round | Real JPEG thumbnail (80x60, ~1KB, 6 chunks) |
| Channel | `CH` | Channel broadcast, each device to all others | Text with nonce |

With 4 devices, each round = ~28 tests (12 DM pairs + 1 ACK + 1 BIN + 1 VMO + 12 CH + optionally 1 IMG).

### Quick Start

```bash
cd meshreliable-app

# Auto-detect all connected serial devices, run 8-hour marathon:
python3 -u scripts/serial_marathon.py

# 2-hour marathon with 2s delay between tests:
python3 -u scripts/serial_marathon.py --duration 2 --delay 2

# Include a BLE-connected device:
python3 -u scripts/serial_marathon.py --ble "T3-S3 V1"

# Specific serial ports only:
python3 -u scripts/serial_marathon.py --ports /dev/cu.usbmodem101,/dev/cu.usbmodem1101

# Log to file:
python3 -u scripts/serial_marathon.py --duration 2 2>&1 | tee /tmp/marathon.log
```

### CLI Options

| Flag | Default | Description |
|------|---------|-------------|
| `--duration` | 8 | Marathon duration in hours |
| `--delay` | 1 | Seconds between individual tests (LoRa needs ~1s minimum) |
| `--ports` | auto-detect | Comma-separated serial port paths |
| `--ble` | none | BLE device name (can specify multiple: `--ble "T3-S3 V1" --ble "XIAO"`) |

### Inter-Test Delay

The `--delay` controls idle time between tests. Key considerations:

- **1 second** (default): Maximum throughput. LoRa is half-duplex — the radio needs a brief window between TX and RX. 1s is sufficient for single-hop.
- **2-3 seconds**: Safer for multi-hop meshes or when devices relay through intermediaries.
- **8-10 seconds**: Conservative. Use if seeing high failure rates due to channel contention.

The MediaTransfer tests (VMO, IMG) have their own internal pacing (3s between chunks) regardless of `--delay`, since multi-chunk transfers need LoRa airtime for each packet.

### Device Map

The script auto-detects devices by serial port. The built-in device map:

| Port | Device | Node Number |
|------|--------|-------------|
| `/dev/cu.usbmodem101` | XIAO | 1550340734 |
| `/dev/cu.usbmodem1101` | Pager #1 | 2712908800 |
| `/dev/cu.usbmodem21101` | Pager #2 | 2712908928 |
| `/dev/cu.usbmodem21201` | T3-S3 V1 | 1634999779 |

Port assignments can change on USB re-enumeration. Run `ls /dev/cu.usbmodem*` to verify.

### BLE Testing

Use `--ble "DeviceName"` to connect to a device via Bluetooth Low Energy instead of serial. This tests the full BLE stack (GATT service, TORADIO/FROMRADIO characteristics).

Requirements:
- `bleak` Python package (installed with meshtastic)
- Device must be BLE-advertising (not already paired to another client)

Note: A device connected via BLE from the test script cannot simultaneously be connected to the iOS/Android app. To test with the phone app active, connect that device via serial instead and let the phone maintain the BLE connection independently.

### Output Format

```
[HH:MM:SS]   DM ✓ XIAO         → T3-S3 V1     (0.9s)
[HH:MM:SS]   DM ✗ Pager #1     → XIAO
[HH:MM:SS]   VMO✓ XIAO         →vmo→ Pager #1     (6.2s)
```

- `✓` = delivered, latency in parentheses
- `✗` = timed out (15s for DM/ACK/BIN/CH, 60s for VMO/IMG)

Round summaries show per-round and cumulative stats:
```
  Round 12: 27/28 | Overall: 295/328 (89.9%) | Elapsed: 64m
```

### MediaTransfer Protocol

Voice memo and image tests use the full MediaTransfer chunked protocol:

1. **START** — announces transfer (total size, chunk count, content type, CRC32)
2. **CHUNK × N** — sends data in 200-byte chunks, paced at 3s intervals
3. **COMPLETE** — signals end of transfer with CRC32
4. **ACK_COMPLETE** — receiver confirms successful reassembly (CRC match)

The test script generates real payloads:
- **Voice Memo**: Codec2 Mode 1300 encoded 440Hz sine wave (pycodec2 library)
- **Image**: JPEG thumbnail with random gradient (Pillow library)

Falls back to random bytes if pycodec2/Pillow are not installed.

### Dependencies

```bash
pip3 install --user meshtastic pycodec2 Pillow
brew install codec2  # required by pycodec2
```

### Interpreting Results

| Rate | Assessment |
|------|-----------|
| >98% | Excellent — production ready |
| 95-98% | Good — occasional packet loss, normal for LoRa |
| 90-95% | Acceptable — investigate specific failing pairs |
| <90% | Issues — check device placement, antenna, serial contention |

Common failure patterns:
- **One device always fails to receive**: Serial buffer contention (too many simultaneous connections) or antenna/placement issue
- **Channel broadcasts fail but DMs work**: Channel uses different routing (flood vs directed)
- **Failures after IMG test**: Radio congestion from multi-chunk transfer; increase delay
- **BLE device failures**: BLE GATT overhead adds latency; consider longer timeouts
