#!/usr/bin/env python3
"""Tests for bin/hass-bar-layout, the fallback used when the shell refuses layout edits from QML."""
import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest

HELPER = os.path.join(os.path.dirname(__file__), "..", "bin", "hass-bar-layout")
SOURCE = "$HOME/.config/omarchy/plugins/hass/DataBarWidget.qml"


def entity(entity_id):
    return {"id": "hass.data.entity." + entity_id, "source": SOURCE, "dataKind": "entity", "entityId": entity_id}


def room(device_id):
    return {"id": "hass.data.room." + device_id, "source": SOURCE, "dataKind": "room", "deviceId": device_id}


class BarLayoutHelper(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "shell.json")
        self.addCleanup(self.dir.cleanup)

    def write(self, layout):
        with open(self.path, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "bar": {"layout": layout}}, handle)

    def run_helper(self, action, entry):
        env = dict(os.environ, HASS_BAR_LAYOUT_CONFIG=self.path, HASS_BAR_LAYOUT_NO_RELOAD="1")
        payload = base64.b64encode(json.dumps(entry).encode()).decode()
        return subprocess.run([sys.executable, HELPER, action, payload], env=env, capture_output=True, text=True)

    def layout(self):
        with open(self.path, encoding="utf-8") as handle:
            return json.load(handle)["bar"]["layout"]

    def test_add_goes_after_the_main_entry_and_after_earlier_data_instances(self):
        self.write({"left": [], "center": [{"id": "hass"}, entity("sensor.a"), {"id": "x"}], "right": []})
        self.assertEqual(self.run_helper("add", entity("sensor.b")).returncode, 0)
        ids = [e["id"] for e in self.layout()["center"]]
        self.assertEqual(ids, ["hass", "hass.data.entity.sensor.a", "hass.data.entity.sensor.b", "x"])

    def test_add_without_a_main_entry_appends_to_the_right_section(self):
        self.write({"left": [], "center": [], "right": [{"id": "clock"}]})
        self.run_helper("add", room("r1"))
        self.assertEqual([e["id"] for e in self.layout()["right"]], ["clock", "hass.data.room.r1"])

    def test_adding_twice_keeps_one_entry_and_remove_takes_it_out(self):
        self.write({"left": [], "center": [], "right": []})
        self.run_helper("add", entity("sensor.a"))
        self.run_helper("add", entity("sensor.a"))
        self.assertEqual(len(self.layout()["right"]), 1)
        self.run_helper("remove", entity("sensor.a"))
        self.assertEqual(self.layout()["right"], [])

    def test_a_missing_file_starts_from_the_default_layout_and_sets_the_version(self):
        self.assertEqual(self.run_helper("add", entity("sensor.a")).returncode, 0)
        with open(self.path, encoding="utf-8") as handle:
            data = json.load(handle)
        self.assertEqual(data["version"], 1)
        self.assertEqual(data["bar"]["layout"]["right"][-1]["id"], "hass.data.entity.sensor.a")

    def test_rejects_entries_that_are_not_data_instances_and_bad_input(self):
        self.write({"left": [], "center": [], "right": []})
        self.assertEqual(self.run_helper("add", {"id": "omarchy.clock"}).returncode, 2)
        env = dict(os.environ, HASS_BAR_LAYOUT_CONFIG=self.path, HASS_BAR_LAYOUT_NO_RELOAD="1")
        self.assertEqual(subprocess.run([sys.executable, HELPER, "add", "***"], env=env, capture_output=True).returncode, 2)
        self.assertEqual(self.layout()["right"], [])


if __name__ == "__main__":
    unittest.main()
