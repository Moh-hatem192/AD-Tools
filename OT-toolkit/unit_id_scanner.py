#!/usr/bin/env python3
"""
Modbus Unit ID scanner - Session 3 Lab
Scans Unit IDs 1-255 to find active devices.
Useful against gateway devices that forward to multiple serial slaves.

Usage:
    python3 unit_id_scanner.py --target <ip> --port <port>
"""

import argparse
import socket
import struct

def probe_unit(target, port, unit_id, timeout=0.1):
    mbap = struct.pack('>HHHB', 1, 0x0000, 6, unit_id)
    pdu = struct.pack('>BHH', 0x03, 0, 1)
    req = mbap + pdu

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((target, port))
        s.sendall(req)
        resp = s.recv(1024)
        s.close()
        if len(resp) >= 9 and resp[7] == 0x03:
            return True
        elif len(resp) >= 9 and resp[7] == 0x83:
            return True  # exception = device is there but rejected
    except Exception:
        return False
    return False

def scan(target, port, timeout):
    print(f"[*] Scanning Unit IDs 1-255 on {target}:{port}")
    print()
    active = []
    for uid in range(1, 256):
        if probe_unit(target, port, uid, timeout=timeout):
            print(f"    [+] Unit ID {uid:<4} active")
            active.append(uid)
    print()
    print(f"[*] Scan complete. {len(active)} active Unit IDs: {active}")

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--target', required=True)
    p.add_argument('--port', type=int, default=502)
    p.add_argument('--timeout', type=float, default=0.1, help='Socket timeout per Unit ID probe')
    args = p.parse_args()
    scan(args.target, args.port, args.timeout)
