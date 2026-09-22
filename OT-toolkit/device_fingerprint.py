#!/usr/bin/env python3
"""
Device fingerprinting via Modbus FC43 - Session 3 Lab
Sends a Read Device Identification request and parses the response
to extract vendor, product, and firmware information.

Usage:
    python3 device_fingerprint.py --target <ip> --port <port>
"""

import argparse
import socket
import struct

def fingerprint(target, port):
    print(f"[*] Fingerprinting {target}:{port}")

    # FC43 / MEI type 0x0E / ReadDeviceId code 0x01 / Object ID 0x00
    mbap = struct.pack('>HHHB', 1, 0x0000, 5, 1)
    pdu = struct.pack('BBBB', 0x2B, 0x0E, 0x01, 0x00)
    req = mbap + pdu

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect((target, port))
    s.sendall(req)
    resp = s.recv(1024)
    s.close()

    if len(resp) < 15:
        print("[!] Short response, not a Modbus device?")
        return

    fc = resp[7]
    if fc != 0x2B:
        print(f"[!] Device does not support FC43 (got FC={fc:#x})")
        return

    # Parse the FC43/MEI payload from the Modbus PDU.
    pdu = resp[7:]
    if len(pdu) < 7:
        print("[!] Short FC43 response")
        return

    if pdu[1] == 0x0E:
        num_objects = pdu[6]
        offset = 7
    else:
        # Fallback for older malformed lab responses that omitted the MEI type.
        num_objects = pdu[5]
        offset = 6

    print(f"[+] Device returned {num_objects} identification objects:")
    print()
    labels = {
        0x00: "Vendor Name",
        0x01: "Product Code",
        0x02: "Major/Minor Revision",
        0x03: "Vendor URL",
        0x04: "Product Name",
        0x05: "Model Name",
        0x06: "User Application Name"
    }
    try:
        for _ in range(num_objects):
            if offset + 2 > len(pdu):
                raise ValueError("truncated object header")
            obj_id = pdu[offset]
            obj_len = pdu[offset + 1]
            end = offset + 2 + obj_len
            if end > len(pdu):
                raise ValueError("truncated object value")
            obj_val = pdu[offset + 2:end].decode('utf-8', errors='replace')
            label = labels.get(obj_id, f"Object {obj_id:#x}")
            print(f"    {label:<28} {obj_val}")
            offset = end
    except Exception as e:
        print(f"[!] Parse error: {e}")

    print()
    print("[*] Use this information to search for known CVEs:")
    print("    https://nvd.nist.gov/vuln/search")
    print("    https://www.cisa.gov/news-events/cybersecurity-advisories")

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--target', required=True)
    p.add_argument('--port', type=int, default=502)
    args = p.parse_args()
    fingerprint(args.target, args.port)
