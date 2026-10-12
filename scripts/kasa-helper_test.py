"""Tests for scripts/kasa-helper.py. No device and no TP-Link login.

Run with the helper environment:

    "$HOME/Library/Application Support/LampBar/kasa-venv/bin/python" scripts/kasa-helper_test.py
"""

import asyncio
import contextlib
import copy
import importlib.util
import io
import json
import subprocess
import sys
import unittest
from pathlib import Path

from kasa import Credentials, DeviceType
from kasa.device_factory import get_device_class_from_sys_info
from kasa.deviceconfig import (
    DeviceConfig,
    DeviceConnectionParameters,
    DeviceEncryptionType,
    DeviceFamily,
)
from kasa.exceptions import KasaException
from kasa.iot import IotPlug, IotStrip

HELPER_PATH = Path(__file__).with_name("kasa-helper.py")
SECRET = "fixture-secret"

KP303 = {
    "alias": "Office strip",
    "child_num": 3,
    "children": [
        {"alias": "Plug 1", "id": "00", "state": 1, "on_time": 10},
        {"alias": "Plug 2", "id": "01", "state": 0, "on_time": 0},
        {"alias": "Plug 3", "id": "02", "state": 1, "on_time": 5},
    ],
    "deviceId": "8006000000000000000000000000000000000001",
    "feature": "TIM",
    "hw_ver": "2.0",
    "led_off": 0,
    "mac": "78:20:51:00:00:00",
    "mic_type": "IOT.SMARTPLUGSWITCH",
    "model": "KP303(US)",
    "sw_ver": "1.1.2",
}

HS103 = {
    "alias": "Desk lamp",
    "deviceId": "8006000000000000000000000000000000000002",
    "feature": "TIM",
    "hw_ver": "1.0",
    "led_off": 0,
    "mac": "78:20:51:00:00:22",
    "mic_type": "IOT.SMARTPLUGSWITCH",
    "model": "HS103(US)",
    "relay_state": 1,
    "sw_ver": "1.0.3",
}


def load_helper():
    spec = importlib.util.spec_from_file_location("kasa_helper", HELPER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper = load_helper()


def klap_config(host):
    return DeviceConfig(
        host=host,
        timeout=1,
        credentials=Credentials("not-used@example.com", SECRET),
        connection_type=DeviceConnectionParameters(
            DeviceFamily.IotSmartPlugSwitch,
            DeviceEncryptionType.Klap,
            2,
        ),
    )


class ScriptedProtocol:
    """Answers kasa queries from a saved sysinfo. Opens no socket."""

    def __init__(self, host, sysinfo, config):
        self.sysinfo = sysinfo
        self.queries = []
        self.closed = False

        class Transport:
            _host = host
            _config = config

        self._transport = Transport()

    @property
    def config(self):
        return self._transport._config

    async def query(self, request):
        self.queries.append(request)
        response = {}
        for key, val in request.items():
            if key == "context" or not isinstance(val, dict):
                continue
            if key == "system" and "get_sysinfo" in val:
                response[key] = {"get_sysinfo": copy.deepcopy(self.sysinfo), "err_code": 0}
            elif key == "time":
                response[key] = {"err_code": 0}
            else:
                body = {cmd: {"err_code": 0} for cmd in val}
                body["err_code"] = 0
                response[key] = body
        return response

    async def close(self):
        self.closed = True


def scripted(cls, host, sysinfo):
    protocol = ScriptedProtocol(host, sysinfo, klap_config(host))
    return cls(host, protocol=protocol), protocol


class KasaHelperTests(unittest.TestCase):
    def test_factory_needs_the_sysinfo_envelope(self):
        with self.assertRaises(KasaException):
            get_device_class_from_sys_info(KP303)
        self.assertIs(get_device_class_from_sys_info({"system": {"get_sysinfo": KP303}}), IotStrip)
        self.assertIs(get_device_class_from_sys_info({"system": {"get_sysinfo": HS103}}), IotPlug)

    def test_misclassified_kp303_becomes_a_strip_on_the_same_protocol(self):
        plug, protocol = scripted(IotPlug, "192.0.2.25", KP303)
        asyncio.run(plug.update())
        with self.assertRaises(KeyError) as raised:
            plug.is_on
        self.assertEqual(raised.exception.args, ("relay_state",))

        prepared = asyncio.run(helper.prepare(plug))

        self.assertIsInstance(prepared, IotStrip)
        self.assertIs(prepared.protocol, protocol)
        self.assertEqual(
            [(child.alias, child.is_on) for child in prepared.children],
            [("Plug 1", True), ("Plug 2", False), ("Plug 3", True)],
        )
        outlets = helper.outlets(prepared)
        self.assertEqual([item["isOn"] for item in outlets], [True, False, True])
        self.assertEqual(outlets[0]["childID"], "78:20:51:00:00:00_00")
        self.assertTrue(all(item["viaHelper"] for item in outlets))

    def test_single_plug_is_not_rebuilt(self):
        plug, _protocol = scripted(IotPlug, "192.0.2.22", HS103)
        prepared = asyncio.run(helper.prepare(plug))
        self.assertIs(prepared, plug)
        outlets = helper.outlets(prepared)
        self.assertEqual(len(outlets), 1)
        self.assertIsNone(outlets[0]["childID"])
        self.assertTrue(outlets[0]["isOn"])
        self.assertEqual(outlets[0]["alias"], "Desk lamp")

    def test_strip_that_is_already_a_strip_is_not_rebuilt(self):
        strip, _protocol = scripted(IotStrip, "192.0.2.25", KP303)
        prepared = asyncio.run(helper.prepare(strip))
        self.assertIs(prepared, strip)
        self.assertEqual(prepared.device_type, DeviceType.Strip)
        self.assertEqual(len(prepared.children), 3)

    def test_discover_keeps_the_other_plugs_when_one_device_fails(self):
        strip, strip_protocol = scripted(IotPlug, "192.0.2.25", KP303)
        desk, desk_protocol = scripted(IotPlug, "192.0.2.22", HS103)
        broken = BrokenPlug()
        legacy = LegacyPlug()

        async def fake_discover(*, target, credentials, discovery_timeout):
            self.assertEqual(target, "192.0.2.255")
            self.assertEqual(discovery_timeout, 3)
            self.assertEqual(credentials.password, SECRET)
            return {
                legacy.host: legacy,
                broken.host: broken,
                strip.host: strip,
                desk.host: desk,
            }

        original = helper.Discover.discover
        helper.Discover.discover = fake_discover
        stderr = io.StringIO()
        try:
            with contextlib.redirect_stderr(stderr):
                outlets = asyncio.run(
                    helper.discover(
                        {"targets": ["192.0.2.255"]},
                        Credentials("not-used@example.com", SECRET),
                    )
                )
        finally:
            helper.Discover.discover = original

        noted = stderr.getvalue()
        self.assertEqual(noted.splitlines(), ["KeyError"])
        self.assertNotIn(SECRET, noted)
        self.assertNotIn(SECRET, json.dumps(outlets))
        hosts = [item["host"] for item in outlets]
        self.assertEqual(hosts.count("192.0.2.25"), 3)
        self.assertEqual(hosts.count("192.0.2.22"), 1)
        self.assertNotIn(broken.host, hosts)
        self.assertNotIn(legacy.host, hosts)
        self.assertTrue(broken.disconnected)
        self.assertFalse(legacy.disconnected)
        self.assertTrue(strip_protocol.closed)
        self.assertTrue(desk_protocol.closed)

    def test_set_switches_the_rebuilt_socket(self):
        plug, protocol = scripted(IotPlug, "192.0.2.25", KP303)

        async def fake_single(host, *, credentials):
            self.assertEqual(host, "192.0.2.25")
            self.assertEqual(credentials.password, SECRET)
            return plug

        original = helper.Discover.discover_single
        helper.Discover.discover_single = fake_single
        try:
            outlets = asyncio.run(
                helper.set_power(
                    {"host": "192.0.2.25", "child": "78:20:51:00:00:00_01", "on": False},
                    Credentials("not-used@example.com", SECRET),
                )
            )
        finally:
            helper.Discover.discover_single = original

        commands = [
            query["system"]["set_relay_state"]
            for query in protocol.queries
            if "system" in query and "set_relay_state" in query["system"]
        ]
        self.assertEqual(commands, [{"state": 0}])
        child_ids = [
            query["context"]["child_ids"]
            for query in protocol.queries
            if "context" in query and "set_relay_state" in query.get("system", {})
        ]
        self.assertEqual(child_ids, [["01"]])
        self.assertEqual([item["isOn"] for item in outlets], [True, False, True])
        self.assertNotIn(SECRET, json.dumps(outlets))
        self.assertTrue(protocol.closed)

    def test_process_error_is_the_type_only(self):
        completed = subprocess.run(
            [sys.executable, "-I", str(HELPER_PATH)],
            input=json.dumps(
                {
                    "command": "unknown",
                    "username": "not-used@example.com",
                    "password": SECRET,
                }
            ),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(completed.stdout.strip(), '{"error": "ValueError"}')
        self.assertNotIn(SECRET, completed.stdout)
        self.assertNotIn(SECRET, completed.stderr)


class BrokenPlug:
    """Updated plug whose is_on still reads a missing relay_state."""

    host = "192.0.2.23"
    alias = "Broken"
    model = "HS103(US)"
    device_id = "broken"
    children = []
    device_type = DeviceType.Plug
    sys_info = {"alias": "Broken", "model": "HS103(US)"}

    def __init__(self):
        self.config = klap_config(self.host)
        self.disconnected = False

    async def update(self):
        return None

    async def disconnect(self):
        self.disconnected = True

    @property
    def is_on(self):
        raise KeyError("relay_state")


class LegacyPlug:
    host = "192.0.2.21"

    def __init__(self):
        self.config = DeviceConfig(host=self.host)
        self.disconnected = False

    async def update(self):
        raise AssertionError("legacy device was updated")

    async def disconnect(self):
        self.disconnected = True


if __name__ == "__main__":
    unittest.main()
