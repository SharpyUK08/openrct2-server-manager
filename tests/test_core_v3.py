import json
import asyncio
import io
import os
import socket
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from openrct2_manager.backups import ArchiveBuilder, BackupInput
from openrct2_manager.bridge import BridgeEvent, CommandBridge
from openrct2_manager.commands import CommandGrantStore
from openrct2_manager.events import EventBroker, TooManySubscribers
from openrct2_manager.jobs import JobStore, work_once
from openrct2_manager.motd import MotdStore, validate_lines
from openrct2_manager.permission_requests import PermissionRequestStore
from openrct2_manager.openrct2 import ConfigStore, Group, GroupDocument, GroupService
from openrct2_manager.overrides import PlayerOverride, OverrideStore, derived_group_name, plan_derived_groups
from openrct2_manager.scenarios import ScenarioStore, safe_filename
from openrct2_manager.security import PortalUserStore, SessionStore, hash_password, verify_password


class CoreV3Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_portal_passwords_rbac_and_last_owner_invariant(self):
        users = PortalUserStore(self.root / "portal-users.json")
        owner = users.create("sam", "Sam", "owner", "correct horse battery staple")
        viewer = users.create("viewer", "Read only", "viewer", "a different long password")
        self.assertNotIn("correct horse", (self.root / "portal-users.json").read_text())
        self.assertEqual(users.authenticate("sam", "correct horse battery staple"), owner)
        self.assertIsNone(users.authenticate("sam", "incorrect password"))
        self.assertTrue(owner.allows("portal-users.manage"))
        self.assertFalse(viewer.allows("server.control"))
        with self.assertRaises(ValueError):
            users.delete(owner.id)
        users.delete(viewer.id)
        self.assertEqual([item.username for item in users.all()], ["sam"])

    def test_password_hash_rejects_malformed_and_short_values(self):
        encoded = hash_password("this is a sufficiently long password", iterations=100_000)
        self.assertTrue(verify_password("this is a sufficiently long password", encoded))
        self.assertFalse(verify_password("nope", encoded))
        self.assertFalse(verify_password("anything", "broken"))
        with self.assertRaises(ValueError):
            hash_password("too short")

    def test_sessions_expire_and_have_distinct_csrf_tokens(self):
        sessions = SessionStore(lifetime_seconds=1)
        one = sessions.create("user"); two = sessions.create("user")
        self.assertNotEqual(one.token, two.token); self.assertNotEqual(one.csrf, two.csrf)
        sessions.revoke(one.token); self.assertIsNone(sessions.get(one.token)); self.assertIsNotNone(sessions.get(two.token))

    def test_group_schema_and_live_bridge(self):
        groups_path = self.root / "groups.json"
        groups_path.write_text(json.dumps({"default_group": 2, "groups": [
            {"id": 0, "name": "Admin", "permissions": ["PERMISSION_CHAT"]},
            {"id": 2, "name": "User", "permissions": ["PERMISSION_CHAT", "PERMISSION_SCENERY"]},
        ]}))
        document = GroupService(groups_path).read_offline()
        self.assertEqual(document.default_group, 2)
        self.assertEqual(document.groups[1].permissions, ("PERMISSION_CHAT", "PERMISSION_SCENERY"))
        calls = []
        class Bridge:
            def request(self, action, **fields):
                calls.append((action, fields))
                return document.json()
        service = GroupService(groups_path, Bridge())
        service.set_permission(2, "PERMISSION_TOGGLE_SCENERY_CLUSTER", True)
        self.assertEqual(calls[-1][0], "group_permission")
        with self.assertRaises(ValueError):
            service.set_permission(0, "PERMISSION_CHAT", False)
        with self.assertRaises(ValueError):
            GroupDocument.parse({"default_group": 9, "groups": []})

    def test_per_player_overrides_create_minimal_effective_groups(self):
        groups = (
            Group(0, "Admin", ("PERMISSION_CHAT", "PERMISSION_CHEAT")),
            Group(2, "Player", ("PERMISSION_CHAT", "PERMISSION_SCENERY")),
        )
        first = PlayerOverride("a" * 40, 2, ("PERMISSION_TOGGLE_SCENERY_CLUSTER",), ())
        second = PlayerOverride("b" * 40, 2, ("PERMISSION_TOGGLE_SCENERY_CLUSTER",), ())
        plan = plan_derived_groups(groups, [first, second])
        self.assertEqual(len(plan), 1)
        effective = next(iter(plan.values()))
        self.assertIn("PERMISSION_TOGGLE_SCENERY_CLUSTER", effective)
        self.assertIn("PERMISSION_SCENERY", effective)
        store = OverrideStore(self.root / "overrides.json"); store.set(first)
        self.assertEqual(store.all(), [first])

    def test_config_updates_supported_keys_without_plaintext_readback(self):
        path = self.root / "config.ini"
        path.write_text('[network]\nserver_name = "Old"\ndefault_password = "secret"\ncustom = keep\n\n[general]\nautosave = 1\nautosave_amount = 10\n')
        store = ConfigStore(path)
        updated = store.update({
            "server_name": "New server", "server_description": "Description", "server_greeting": "Welcome",
            "max_players": 24, "default_port": 11753, "advertise": True,
            "advertise_address": "203.0.113.10", "pause_when_empty": True,
            "autosave": 2, "autosave_amount": 30,
        })
        self.assertEqual(updated.server_name, "New server"); self.assertTrue(updated.has_password)
        self.assertEqual(updated.autosave_amount, 30)
        self.assertIn("custom = keep", path.read_text())

    def test_scenario_store_blocks_path_traversal_and_supports_legacy_sv4(self):
        store = ScenarioStore(self.root / "scenarios", max_upload_bytes=100)
        uploaded = store.upload([("Park.park", b"park"), ("Legacy.sv4", b"save")])
        self.assertEqual({item.format for item in uploaded}, {"park", "sv4"})
        with self.assertRaises(ValueError):
            safe_filename("../secret.park")
        with self.assertRaises(ValueError):
            store.upload([("Park.park", b"replace")])
        selection = self.root / "selected"
        store.select("Legacy.sv4", selection)
        self.assertEqual(selection.read_text(), "Legacy.sv4\n")

    def test_scenario_streaming_upload_is_bounded(self):
        store = ScenarioStore(self.root / "streamed", max_upload_bytes=8)
        uploaded = store.upload_streams([("Small.park", io.BytesIO(b"12345678"))])
        self.assertEqual(uploaded[0].size, 8)
        with self.assertRaises(ValueError):
            store.upload_streams([("Large.park", io.BytesIO(b"123456789"))])
        self.assertFalse((self.root / "streamed" / "Large.park").exists())

    def test_motd_is_validated_persisted_and_pushed_live(self):
        calls = []
        class Bridge:
            def request(self, action, **fields):
                calls.append((action, fields)); return {"ok": True}
        store = MotdStore(self.root / "motd.json", Bridge())
        self.assertEqual(store.set(["Welcome builders", "Use /help"]), ("Welcome builders", "Use /help"))
        self.assertEqual(store.get(), ("Welcome builders", "Use /help"))
        self.assertEqual(calls[0][0], "set_motd")
        with self.assertRaises(ValueError):
            validate_lines(["bad\nline"])

    def test_command_grants_are_per_player_and_per_command(self):
        calls = []
        class Bridge:
            def request(self, action, **fields):
                calls.append((action, fields)); return {"ok": True}
        store = CommandGrantStore(self.root / "command-grants.json", Bridge())
        grants = store.set("a" * 40, "save", True)
        self.assertEqual(grants, ("save",))
        self.assertNotIn("backup", grants)
        self.assertEqual(calls[-1][1]["command"], "save")
        self.assertEqual(store.set("a" * 40, "save", False), ())

    def test_permission_requests_are_idempotent_and_resolve_once(self):
        store = PermissionRequestStore(self.root / "requests.sqlite3"); self.addCleanup(store.close)
        event = BridgeEvent("request-0001", "permission_request", 7, "Alex", "b" * 40,
                            time.monotonic(), "PERMISSION_TOGGLE_SCENERY_CLUSTER", "scenery-brush")
        self.assertTrue(store.add(event)); self.assertFalse(store.add(event))
        self.assertEqual(store.pending()[0].player_name, "Alex")
        resolved = store.resolve("request-0001", approved=True, portal_user_id="owner-id")
        self.assertEqual(resolved.status, "approved")
        with self.assertRaises(ValueError):
            store.resolve("request-0001", approved=False, portal_user_id="owner-id")

    def test_durable_job_queue_retries_without_blocking_request_thread(self):
        store = JobStore(self.root / "jobs.sqlite3"); self.addCleanup(store.close)
        job_id = store.enqueue("backup", {"scope": "full"})
        handled = []
        self.assertTrue(work_once(store, {"backup": handled.append}))
        self.assertEqual(handled, [{"scope": "full"}])
        status = store.connection.execute("SELECT status FROM jobs WHERE id=?", (job_id,)).fetchone()[0]
        self.assertEqual(status, "complete")

    def test_event_broker_bounds_slow_subscribers(self):
        async def exercise():
            broker = EventBroker(max_subscribers=1, queue_size=2)
            stream = broker.subscribe(heartbeat_seconds=0.01, max_lifetime_seconds=1)
            self.assertEqual(await stream.__anext__(), b"retry: 3000\n\n")
            broker.publish("telemetry", {"value": 1})
            broker.publish("telemetry", {"value": 2})
            broker.publish("telemetry", {"value": 3})
            self.assertEqual(broker.dropped_events, 1)
            with self.assertRaises(TooManySubscribers):
                await broker.subscribe().__anext__()
            self.assertIn(b'"value":2', await stream.__anext__())
            await stream.aclose()
            self.assertEqual(broker.subscriber_count, 0)
        asyncio.run(exercise())

    def test_backup_manifest_covers_portal_settings_and_game_data(self):
        state = self.root / "state"; saves = self.root / "save"; logs = self.root / "logs"
        state.mkdir(); saves.mkdir(); logs.mkdir()
        (state / "portal-users.json").write_text('{"schema":1}')
        (state / "settings.json").write_text("{}")
        (saves / "park.park").write_bytes(b"park")
        (logs / "server.log").write_text("started")
        result = ArchiveBuilder(self.root / "backups").create([
            BackupInput(state, "manager-state"), BackupInput(saves, "ServerData/save"),
            BackupInput(logs, "logs"),
        ], app_version="test")
        self.assertEqual(len(result.sha256), 64)
        with tarfile.open(result.path) as archive:
            names = archive.getnames()
            self.assertIn("manager-state/portal-users.json", names)
            self.assertIn("ServerData/save/park.park", names)
            manifest = json.load(archive.extractfile("manifest.json"))
            self.assertEqual(manifest["application_version"], "test")
            self.assertTrue(any(item["path"] == "logs/server.log" for item in manifest["files"]))

    def test_command_bridge_authenticates_and_rate_limits(self):
        events = []
        bridge = CommandBridge("x" * 64, {"backup": events.append}, port=0)
        port = bridge.server.server_address[1]
        bridge.start(); self.addCleanup(bridge.stop)
        payload = {"token": "x" * 64, "action": "backup", "player_id": 3,
                   "event_id": "event-0001",
                   "player_name": "Sam", "public_key_hash": "a" * 40}
        for _ in range(2):
            with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
                client.sendall((json.dumps(payload) + "\n").encode()); self.assertIn(b'true', client.recv(100))
        limit = time.time() + 2
        while not events and time.time() < limit:
            time.sleep(0.01)
        self.assertEqual(len(events), 1)


if __name__ == "__main__":
    unittest.main()
