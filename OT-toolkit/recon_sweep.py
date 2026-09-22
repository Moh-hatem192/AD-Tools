#!/usr/bin/env python3
"""
Register enumeration sweep - Session 3 Lab
Identifies active registers by reading the entire holding register space
and flagging non-zero values.

Usage:
    python3 recon_sweep.py --target <ip> --port <port>
"""

import argparse
import socket
import struct
import sys
import time

def build_read_request(tid, addr, count):
    mbap = struct.pack('>HHHB', tid, 0x0000, 6, 1)
    pdu = struct.pack('>BHH', 0x03, addr, count)
    return mbap + pdu

def parse_response(data):
    if len(data) < 9:
        return ("short", None)
    fc = data[7]
    if fc & 0x80:
        return ("exception", data[8])
    byte_count = data[8]
    values = []
    for i in range(byte_count // 2):
        val = struct.unpack('>H', data[9 + i*2 : 11 + i*2])[0]
        values.append(val)
    return ("ok", values)

def sweep(target, port, start=0, end=10000, block_size=50):
    print(f"[*] Sweeping registers {start}-{end} on {target}:{port}")
    print("[*] Enumerating one address at a time to catch sparse maps and zero-valued registers")
    print()

    active = []
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(3)
    try:
        sock.connect((target, port))
    except Exception as e:
        print(f"[!] Connection failed: {e}")
        sys.exit(1)

    tid = 1
    for addr in range(start, end):
        req = build_read_request(tid, addr, 1)
        try:
            sock.sendall(req)
            resp = sock.recv(1024)
            status, payload = parse_response(resp)
            if status == "ok":
                active.append((addr, payload[0]))
            elif status == "exception" and payload != 0x02:
                print(f"[!] Modbus exception at addr {addr}: code {payload:#x}")
        except Exception as e:
            print(f"[!] Error at addr {addr}: {e}")
            break
        tid += 1
        time.sleep(0.02)  # avoid flooding

    sock.close()

    print(f"[+] Found {len(active)} active registers:")
    print()
    print(f"    {'Register':<12} {'Wire Addr':<12} {'Value':<10}")
    print(f"    {'-'*34}")
    for addr, val in active:
        mb_num = 40001 + addr
        print(f"    {mb_num:<12} 0x{addr:04X}{'':<6} {val}")

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--target', required=True, help='Target IP or hostname')
    p.add_argument('--port', type=int, default=502, help='Target port')
    p.add_argument('--start', type=int, default=0)
    p.add_argument('--end', type=int, default=100)
    p.add_argument('--block', type=int, default=50)
    args = p.parse_args()
    sweep(args.target, args.port, args.start, args.end, args.block)
