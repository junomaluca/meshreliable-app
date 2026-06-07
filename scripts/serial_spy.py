#!/usr/bin/env python3
"""Read raw serial output from a device and log it."""
import sys
import time
import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbmodem21201"
BAUD = 115200

print(f"Opening {PORT} at {BAUD}...", flush=True)
ser = serial.Serial(PORT, BAUD, timeout=1)
print("Reading... (Ctrl+C to stop)", flush=True)

try:
    while True:
        try:
            data = ser.readline()
        except serial.SerialException:
            print("[serial exception, reconnecting...]", flush=True)
            time.sleep(1)
            try:
                ser.close()
            except:
                pass
            ser = serial.Serial(PORT, BAUD, timeout=1)
            continue
        if data:
            try:
                line = data.decode('utf-8', errors='replace').rstrip()
                if line:
                    print(line, flush=True)
            except:
                print(f"[binary: {data.hex()}]", flush=True)
except KeyboardInterrupt:
    pass
finally:
    ser.close()
