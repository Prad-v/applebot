#!/usr/bin/env python3
"""Print the UDID of a connected iPhone/iPad for `make device`.

Usage:
  select_device.py                 first connected iOS device
  select_device.py "<name or UDID>"  that specific device (substring match on the name)
  select_device.py --list          human-readable table of all known devices

Exit codes: 0 = printed a UDID, 1 = none found / ambiguous (message on stderr).
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


def load_devices() -> list[dict]:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "devices.json"
        result = subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", str(out)],
            capture_output=True, text=True,
        )
        if result.returncode != 0 or not out.exists():
            print(result.stderr.strip() or "devicectl failed", file=sys.stderr)
            sys.exit(1)
        data = json.loads(out.read_text())
    devices = []
    for item in data.get("result", {}).get("devices", []):
        hardware = item.get("hardwareProperties", {})
        props = item.get("deviceProperties", {})
        conn = item.get("connectionProperties", {})
        devices.append({
            "name": props.get("name", "?"),
            "udid": hardware.get("udid", ""),
            "platform": hardware.get("platform", ""),
            "model": hardware.get("marketingName") or hardware.get("productType", ""),
            "os": props.get("osVersionNumber", "?"),
            "state": conn.get("tunnelState", "unknown"),
            "developer_mode": props.get("developerModeStatus", "unknown"),
        })
    return devices


def main() -> int:
    args = sys.argv[1:]
    devices = [d for d in load_devices() if d["platform"] in ("iOS", "iPadOS")]

    if args and args[0] == "--list":
        if not devices:
            print("No iPhone/iPad paired with this Mac.")
            return 0
        print(f"{'NAME':32} {'MODEL':22} {'OS':8} {'STATE':12} UDID")
        for d in devices:
            print(f"{d['name'][:32]:32} {d['model'][:22]:22} {d['os']:8} {d['state']:12} {d['udid']}")
        return 0

    connected = [d for d in devices if d["state"] == "connected"]
    wanted = args[0] if args else ""
    if wanted:
        matches = [d for d in connected if wanted == d["udid"] or wanted.lower() in d["name"].lower()]
    else:
        matches = connected

    if not matches:
        print(
            "No connected iPhone found. Connect it with a cable (or enable Wi-Fi pairing), unlock it, "
            "and tap 'Trust'. Run `make devices` to see what this Mac can see.",
            file=sys.stderr,
        )
        return 1
    if len(matches) > 1 and not wanted:
        names = ", ".join(d["name"] for d in matches)
        print(f"Several devices are connected ({names}). Pick one: make device DEVICE=\"<name or UDID>\"", file=sys.stderr)
        return 1

    chosen = matches[0]
    if chosen["developer_mode"] not in ("enabled", "unknown"):
        print(
            f"Developer Mode is '{chosen['developer_mode']}' on {chosen['name']}. "
            "Enable it in Settings > Privacy & Security > Developer Mode, then restart the phone.",
            file=sys.stderr,
        )
        return 1
    print(chosen["udid"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
