"""Lamp Bar helper for Kasa plugs that need a TP-Link login (KLAP/AES firmware).

The app talks to legacy (XOR) plugs natively. Only plugs with newer firmware go
through this helper, which uses python-kasa. The app sends one JSON request on
stdin, so the login never appears in the process arguments, and reads one JSON
reply on stdout. The helper never prints or logs the login.

Request:  {"command": "discover" | "set", "username": str, "password": str,
           "targets": [broadcast addresses]            (discover)
           "host": str, "child": str | null, "on": bool (set)}
Reply:    {"outlets": [...]} or {"error": str}
"""

import asyncio
import json
import sys

from kasa import Credentials, Discover
from kasa.deviceconfig import DeviceEncryptionType


def outlets(dev):
    base = {
        "deviceID": dev.device_id,
        "host": dev.host,
        "deviceAlias": dev.alias or dev.model,
        "model": dev.model,
        "viaHelper": True,
    }
    if dev.children:
        return [
            dict(base, childID=child.device_id, alias=child.alias or child.device_id, isOn=child.is_on)
            for child in dev.children
        ]
    return [dict(base, childID=None, alias=dev.alias or dev.model, isOn=dev.is_on)]


def needs_login(dev):
    return dev.config.connection_type.encryption_type != DeviceEncryptionType.Xor


async def discover(req, creds):
    found = {}
    for target in req.get("targets") or ["255.255.255.255"]:
        devices = await Discover.discover(target=target, credentials=creds, discovery_timeout=3)
        found.update(devices)
    result = []
    for dev in found.values():
        if not needs_login(dev):
            continue
        try:
            await dev.update()
            result.extend(outlets(dev))
        finally:
            await dev.disconnect()
    return result


async def set_power(req, creds):
    dev = await Discover.discover_single(req["host"], credentials=creds)
    try:
        await dev.update()
        target = dev
        if req.get("child"):
            target = next(c for c in dev.children if c.device_id == req["child"])
        await (target.turn_on() if req["on"] else target.turn_off())
        await dev.update()
        return outlets(dev)
    finally:
        await dev.disconnect()


async def main():
    req = json.loads(sys.stdin.read())
    creds = Credentials(req["username"], req["password"])
    if req["command"] == "discover":
        return await discover(req, creds)
    if req["command"] == "set":
        return await set_power(req, creds)
    raise ValueError("unknown command")


if __name__ == "__main__":
    try:
        print(json.dumps({"outlets": asyncio.run(main())}))
    except Exception as exc:  # report the failure type only; messages can echo request data
        print(json.dumps({"error": type(exc).__name__}))
        sys.exit(1)
