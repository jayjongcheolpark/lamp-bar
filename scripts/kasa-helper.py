"""Lamp Bar helper for Kasa plugs that need a TP-Link login (KLAP/AES firmware).

The app talks to legacy (XOR) plugs natively. Only plugs with newer firmware go
through this helper, which uses python-kasa. The app sends one JSON request on
stdin, so the login never appears in the process arguments, and reads one JSON
reply on stdout. The helper never prints or logs the login.

Request:  {"command": "discover" | "set", "username": str, "password": str,
           "targets": [broadcast addresses]            (discover)
           "host": str, "child": str | null, "on": bool (set)}
Reply:    {"outlets": [...]} or {"error": str}

Discover omits a device that fails and still returns the others. The error
text is the exception type only, so a message cannot echo the request or the login.
"""

import asyncio
import json
import sys

from kasa import Credentials, DeviceType, Discover
from kasa.device_factory import get_device_class_from_sys_info
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


def _note_failure(exc):
    # Type only. Exception text can repeat the request, including the login.
    print(type(exc).__name__, file=sys.stderr)


async def _disconnect(dev):
    try:
        await dev.disconnect()
    except Exception as exc:
        _note_failure(exc)


def _as_strip(dev):
    """Build a strip when sysinfo lists children but the object is a single plug.

    python-kasa 0.11 maps family IOT.SMARTPLUGSWITCH to IotPlug, so a KP303
    has children and no relay_state. The factory reads the get_sysinfo
    envelope, and dev.sys_info is only the inner dict. The new object keeps
    the open protocol: the config-only constructor talks on legacy port 9999.
    """
    info = dev.sys_info
    if not isinstance(info, dict) or not isinstance(info.get("children"), list):
        return None
    if dev.device_type == DeviceType.Strip:
        return None
    cls = get_device_class_from_sys_info({"system": {"get_sysinfo": info}})
    return cls(dev.host, config=dev.config, protocol=dev.protocol)


async def prepare(dev):
    await dev.update()
    rebuilt = _as_strip(dev)
    if rebuilt is None:
        return dev
    await rebuilt.update()
    return rebuilt


async def discover(req, creds):
    found = {}
    for target in req.get("targets") or ["255.255.255.255"]:
        devices = await Discover.discover(target=target, credentials=creds, discovery_timeout=3)
        found.update(devices)
    result = []
    for dev in found.values():
        try:
            if not needs_login(dev):
                continue
        except Exception as exc:
            _note_failure(exc)
            continue
        try:
            dev = await prepare(dev)
            result.extend(outlets(dev))
        except Exception as exc:
            _note_failure(exc)
        finally:
            await _disconnect(dev)
    return result


async def set_power(req, creds):
    dev = await Discover.discover_single(req["host"], credentials=creds)
    try:
        dev = await prepare(dev)
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
