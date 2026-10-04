"""Small, dependency-free checks for the installer-embedded manager."""

import io
import json
import os
import tempfile
import time
import unittest
from types import SimpleNamespace
from pathlib import Path
from unittest import mock


INSTALLER = Path(__file__).resolve().parents[1] / "outputs" / "install-openrct2-manager.sh"


def load_manager():
    installer = INSTALLER.read_text()
    source = installer.split("<<'PYAPP'\n", 1)[1].split("\nPYAPP", 1)[0]
    source = source.replace("ENV = read_env()", "ENV = {}")
    namespace = {"__name__": "openrct2_manager_test"}
    exec(compile(source, str(INSTALLER), "exec"), namespace)
    return namespace


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manager = load_manager()
        for name in ("SCENARIOS", "BACKUPS", "SAVES", "SCENARIO_ARCHIVE"):
            folder = self.root / name.lower()
            folder.mkdir()
            self.manager[name] = folder
        for name in ("SELECTED", "USERS_JSON", "SETTINGS", "ROLE_OVERRIDES", "HELPER", "CONTROL_TOKEN_FILE", "AUDIT_LOG",
                     "PLAYER_PERMISSION_OVERRIDES", "COMMAND_GRANTS", "PERMISSION_REQUESTS", "PORTAL_USERS",
                     "VERSION_CHECK", "BACKUP_DESTINATIONS", "MOTD_FILE", "CONFIG_INI", "JOB_DB", "AUDIT_CHAIN",
                     "SETUP_STATE", "SETUP_COMPLETE", "STATE_VERSION", "CREDENTIALS"):
            self.manager[name] = self.root / name.lower()
        self.manager["HELPER_TEMPLATE"] = Path(__file__).resolve().parents[1] / "production" / "manager-helper.template.js"
        self.manager["CONFIG_INI"].write_text(
            '[network]\nserver_name="Test server"\nserver_description=""\nserver_greeting=""\n'
            'maxplayers=16\ndefault_port=11753\nadvertise=true\nadvertise_address="127.0.0.1"\n'
            'pause_server_if_no_clients=true\ndefault_password=""\n'
            '[general]\nautosave=1\nautosave_amount=10\n')
        self.manager["CREDENTIALS"].write_text("admin:legacy-bootstrap-password\n")
        # Keep rendering tests independent of whether the host has a production logo installed.
        self.manager["LOGO_PNG"] = self.root / "logo.png"
        self.manager["ensure_control_token"]()
        self.actions = []
        self.manager["service_active"] = lambda: False
        self.manager["control_server"] = self.actions.append
        self.manager["wait_for_game_health"] = lambda timeout=15: None
        self.original_activity_text = self.manager["activity_text"]
        self.manager["activity_text"] = lambda mode="chat": "[CHAT] Test player: Hello"
        self.handler = object.__new__(self.manager["Handler"])
        self.handler.portal_user = {"id": "0" * 32, "username": "test-owner", "display_name": "Test Owner",
                                    "role": "owner", "active": True, "password_hash": "pbkdf2_sha256$"}
        self.messages = []
        self.handler.redirect = lambda message="", tab="overview": self.messages.append((tab, message))

    def test_multi_upload_launch_and_identity_controls(self):
        self.handler.upload({}, [("first.park", b"park"), ("second.sc6", b"scenario")])
        self.assertEqual(len(self.manager["scenario_files"]()), 2)
        self.handler.select({"scenario": "second.sc6"})
        self.assertEqual(self.actions, ["start"])
        key = "a" * 40
        self.manager["USERS_JSON"].write_text(json.dumps([
            {"name": "samsharpe", "hash": key, "groupId": 2},
            {"name": "old invalid row", "hash": "", "groupId": 0},
        ]))
        self.handler.permissions({"hash": key, "role": "0"})
        users = json.loads(self.manager["USERS_JSON"].read_text())
        self.assertEqual(users[0]["groupId"], 0)
        self.assertEqual(self.manager["role_overrides"]()[key], 0)
        self.assertEqual(len(users), 2)
        self.handler.block({"hash": key, "mode": "block"})
        self.assertIn(key, self.manager["settings"]()["blocked_hashes"])
        self.handler.block({"hash": key, "mode": "unblock"})
        self.assertNotIn(key, self.manager["settings"]()["blocked_hashes"])

    def test_role_change_while_running_does_not_restart_game(self):
        key = "c" * 40
        self.manager["USERS_JSON"].write_text(json.dumps([
            {"name": "Connected admin", "hash": key, "groupId": 2}
        ]))
        self.manager["service_active"] = lambda: True
        requests = []
        def request(action, **fields):
            requests.append((action, fields))
            if action == "groups":
                return {"groups": [{"id": 0, "name": "Administrator", "permissions": []},
                                    {"id": 2, "name": "Player", "permissions": []}]}
            return {"ok": True}
        self.manager["control_request"] = request
        self.handler.permissions({"hash": key, "role": "0"})
        self.assertEqual(self.actions, [])
        self.assertEqual(requests, [("groups", {}), ("set_role", {"hash": key, "group": 0})])
        self.assertEqual(self.manager["visible_user_roles"]()[0]["groupId"], 0)
        self.assertEqual(json.loads(self.manager["USERS_JSON"].read_text())[0]["groupId"], 2)
        self.assertIn('"' + key + '": 0', self.manager["HELPER"].read_text())

    def test_failed_park_switch_rolls_back_previous_selection(self):
        (self.manager["SCENARIOS"] / "old.park").write_bytes(b"old")
        (self.manager["SCENARIOS"] / "candidate.park").write_bytes(b"candidate")
        self.manager["SELECTED"].write_text("old.park\n")
        self.manager["service_active"] = lambda: True
        safety = self.manager["SAVES"] / "pre-switch-20261004T120000Z.park"
        safety.write_bytes(b"safe")
        self.manager["create_live_switch_save"] = lambda: safety
        health_checks = []
        def health(timeout=15):
            health_checks.append(True)
            if len(health_checks) == 1:
                raise ValueError("candidate did not become healthy")
        self.manager["wait_for_game_health"] = health
        with self.assertRaisesRegex(ValueError, "previous park was restored"):
            self.handler.select({"scenario": "candidate.park"})
        self.assertEqual(self.manager["SELECTED"].read_text(), "old.park\n")
        self.assertEqual(self.actions, ["restart", "restart"])

    def test_kick_is_one_off_and_scenario_archive_is_recoverable(self):
        key = "d" * 40
        self.manager["game_status"] = lambda: {"details": [{"id": 7, "public_key_hash": key}]}
        requests = []
        self.manager["control_request"] = lambda action, **fields: requests.append((action, fields)) or {"ok": True}
        self.handler.kick({"hash": key})
        self.assertEqual(requests, [("kick", {"player_id": 7})])
        self.assertNotIn(key, self.manager["settings"]()["blocked_hashes"])
        park = self.manager["SCENARIOS"] / "spare.park"; park.write_bytes(b"park")
        self.handler.scenario_archive_action({"scenario": park.name, "mode": "archive"})
        self.assertFalse(park.exists()); self.assertTrue((self.manager["SCENARIO_ARCHIVE"] / park.name).exists())
        self.handler.scenario_archive_action({"scenario": park.name, "mode": "restore"})
        self.assertTrue(park.exists())

    def test_remote_connection_test_does_not_upload(self):
        destination = {"type": "rclone", "config": {"remote": "vault", "path": "openrct2"}}
        with mock.patch.object(self.manager["shutil"], "which", return_value="/usr/bin/rclone"), \
             mock.patch.dict(self.manager, {"run": lambda *args, **kwargs: SimpleNamespace(returncode=0, stderr="")}):
            self.assertEqual(self.manager["test_destination"](destination), "vault:openrct2")

    def test_audit_chain_detects_tampering(self):
        self.manager["audit_event"]("Changed setting", actor="owner", target="server", correlation="abc")
        self.manager["audit_event"]("Queued backup", actor="owner", target="backup", outcome="queued", correlation="def")
        self.assertEqual(self.manager["verify_audit_log"](), 2)
        text = self.manager["AUDIT_LOG"].read_text().replace("Queued backup", "Deleted backup")
        self.manager["AUDIT_LOG"].write_text(text)
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.manager["verify_audit_log"]()

    def test_first_run_token_creates_owner_and_is_consumed(self):
        token = "temporary-setup-password-1234"
        self.manager["initialize_setup_token"](token)
        self.assertTrue(self.manager["setup_pending"]())
        self.handler.client_address = ("127.0.0.1", 12345)
        self.handler.read_form = lambda: ({
            "setup_password": token, "username": "owner", "display_name": "Server Owner",
            "password": "a genuinely long owner password", "password_confirm": "a genuinely long owner password",
            "server_name": "Our Coaster Server", "server_description": "Private park",
            "server_greeting": "Welcome builders", "max_players": "24", "advertise": "yes",
            "pause_when_empty": "yes",
        }, None)
        self.manager["detected_openrct2"] = lambda: {"path": "/usr/bin/openrct2", "version": "OpenRCT2 1.0", "healthy": True}
        signed_in = []
        self.handler.start_session = lambda user, location="/": signed_in.append(user)
        self.handler.setup_page = lambda message="": self.fail(message)
        self.handler.finish_setup()
        users = self.manager["portal_users"]()
        self.assertEqual([(user["username"], user["role"]) for user in users], [("owner", "owner")])
        self.assertTrue(self.manager["verify_portal_password"]("a genuinely long owner password", users[0]["password_hash"]))
        self.assertFalse(self.manager["SETUP_STATE"].exists())
        self.assertTrue(self.manager["SETUP_COMPLETE"].exists())
        self.assertFalse(self.manager["setup_pending"]())
        self.assertEqual(self.manager["game_config"]()["server_name"], "Our Coaster Server")
        self.assertEqual(self.manager["game_config"]()["max_players"], 24)
        self.assertEqual(signed_in[0]["username"], "owner")

    def test_consumed_setup_password_cannot_become_a_legacy_owner(self):
        self.manager["SETUP_COMPLETE"].write_text('{"schema":1}\n')
        self.manager["CREDENTIALS"].write_text("owner:!browser-first-run-disabled!\n")
        self.manager["ensure_portal_owner"]()
        self.assertEqual(self.manager["portal_users"](), [])

    def test_first_run_rejects_wrong_token_without_creating_owner(self):
        self.manager["initialize_setup_token"]("temporary-setup-password-1234")
        self.handler.client_address = ("127.0.0.1", 12345)
        self.handler.read_form = lambda: ({"setup_password": "wrong password"}, None)
        messages = []
        self.handler.setup_page = messages.append
        self.handler.finish_setup()
        self.assertIn("incorrect", messages[-1].lower())
        self.assertEqual(self.manager["portal_users"](), [])
        self.assertTrue(self.manager["setup_pending"]())

    def test_first_run_page_shows_detected_install_and_setup_steps(self):
        self.manager["initialize_setup_token"]("temporary-setup-password-1234")
        self.manager["detected_openrct2"] = lambda: {
            "path": "/usr/bin/openrct2-cli", "version": "OpenRCT2, v0.5.5", "healthy": True}
        self.handler.wfile = io.BytesIO()
        self.handler.send_response = lambda *_: None
        self.handler.send_header = lambda *_: None
        self.handler.end_headers = lambda: None
        self.handler.setup_page()
        body = self.handler.wfile.getvalue().decode()
        self.assertIn("Set up your server", body)
        self.assertIn("One-time setup password", body)
        self.assertIn("/usr/bin/openrct2-cli", body)
        self.assertIn("Create the first Owner", body)
        self.assertIn("Server basics", body)
        self.assertIn("Domain and HTTPS", body)
        self.assertNotIn("temporary-setup-password-1234", body)

    def test_setup_completion_provides_safe_https_command(self):
        self.handler.wfile = io.BytesIO()
        self.handler.send_response = lambda *_: None
        self.handler.send_header = lambda *_: None
        self.handler.end_headers = lambda: None
        self.handler.setup_complete_page("parks.example.com")
        body = self.handler.wfile.getvalue().decode()
        self.assertIn("DNS", body); self.assertIn("ports <strong>80</strong> and <strong>443</strong>", body)
        self.assertIn("sudo openrct2-manager-enable-https parks.example.com", body)
        self.assertNotIn("https://https://", body)
        self.handler.wfile = io.BytesIO(); self.handler.setup_complete_page("bad/name")
        self.assertNotIn("bad/name", self.handler.wfile.getvalue().decode())

    def test_quick_save_picker_launch_and_safe_download(self):
        quick_name = "quick-save-20260926T120000123Z.park"
        quick = self.manager["SAVES"] / quick_name
        quick.write_bytes(b"park")
        self.assertEqual(self.manager["quick_save_files"](), [quick])
        self.handler.select({"scenario": "quick:" + quick_name})
        self.assertEqual(self.manager["SELECTED"].read_text().strip(), quick_name)
        self.assertEqual((self.manager["SCENARIOS"] / quick_name).read_bytes(), b"park")
        self.handler.select({"scenario": "quick:" + quick_name})
        self.assertEqual(self.actions, ["start", "start"])
        with self.assertRaises(ValueError):
            self.handler.select({"scenario": "quick:../secret.park"})
        with self.assertRaises(ValueError):
            self.handler.select({"scenario": "quick:manager-snapshot-20260926T120000Z.park"})
        responses = []
        self.handler.wfile = io.BytesIO()
        self.handler.send_response = responses.append
        self.handler.send_header = lambda *_: None
        self.handler.end_headers = lambda: None
        self.handler.download_quick_save(quick_name)
        self.assertEqual(responses[-1], 200)
        self.assertEqual(self.handler.wfile.getvalue(), b"park")
        self.handler.download_quick_save("../secret.park")
        self.assertEqual(responses[-1], 404)

    def test_snapshot_schedule_and_retention(self):
        self.handler.snapshot_settings({"minutes": "5", "keep": "2"})
        self.assertEqual(self.manager["settings"]()["snapshot_minutes"], 5)
        helper = self.manager["HELPER"].read_text()
        self.assertIn("var snapshotMinutes = 5;", helper)
        self.assertIn("var controlPort = 11754;", helper)
        self.assertIn('context.subscribe("interval.tick", function () {', helper)
        self.assertIn('context.saveGame({ filename: "manager-snapshot-" + snapshotStamp });', helper)
        self.assertIn('snapshotDue = true;', helper)
        for index in range(3):
            path = self.manager["SAVES"] / f"manager-snapshot-20260924T00000{index}Z.park"
            path.write_bytes(b"park")
            old = time.time() - 1000 + index
            os.utime(path, (old, old))
        self.manager["prune_snapshots"]()
        self.assertEqual(len(self.manager["snapshot_files"]()), 2)

    def test_all_tabs_render_with_clear_navigation(self):
        self.manager["SCENARIOS"].joinpath("park.park").write_bytes(b"park")
        self.manager["SELECTED"].write_text("park.park")
        self.manager["USERS_JSON"].write_text(json.dumps([
            {"name": "Test player", "hash": "b" * 40, "groupId": 2}
        ]))
        headings = {
            "overview": "Good evening",
            "parks": "Upload once, start at a moment's notice",
            "players": "Know who can do what",
            "groups": "Groups and capabilities",
            "users": "Portal users",
            "backups": "Every recoverable park copy",
            "activity": "What is happening now",
            "settings": "Server settings",
        }
        for tab, heading in headings.items():
            with self.subTest(tab=tab):
                self.handler.path = "/?tab=" + tab
                self.handler.wfile = io.BytesIO()
                self.handler.send_response = lambda *_: None
                self.handler.send_header = lambda *_: None
                self.handler.end_headers = lambda: None
                self.handler.dashboard("Ready", tab)
                body = self.handler.wfile.getvalue().decode()
                self.assertIn(heading, body)
                self.assertIn('href="/logo.svg"', body)
                self.assertIn("aria-current=page", body)
                if tab == "overview":
                    self.assertIn('id="overview-feed"', body)
                    self.assertIn('id="online-count"', body)
                    self.assertNotIn('id="console-dock"', body)
                else:
                    self.assertIn('id="console-dock"', body)
                self.assertIn("Ready", body)
                self.assertIn('id="theme-toggle"', body)
                self.assertIn('openrct2-theme', body)

    def test_overview_status_and_sticky_navigation(self):
        self.manager["service_active"] = lambda: True
        self.manager["control_request"] = lambda action: {"ok": True, "players": 2}
        self.manager["LOGO_PNG"] = self.root / "logo.png"
        self.manager["LOGO_PNG"].write_bytes(b"PNG test")
        self.assertEqual(self.manager["game_status"]()["players"], 2)
        self.handler.path = "/?tab=overview"
        self.handler.wfile = io.BytesIO()
        self.handler.send_response = lambda *_: None
        self.handler.send_header = lambda *_: None
        self.handler.end_headers = lambda: None
        self.handler.dashboard("", "overview")
        body = self.handler.wfile.getvalue().decode()
        self.assertIn('id="online-count">2', body)
        self.assertIn('position:sticky;top:0', body)
        self.assertIn('name="return_tab" value="overview"', body)
        self.assertIn('src="/logo.png"', body)
        self.assertIn('aria-hidden="true"', body)

    def test_manager_actions_appear_in_read_only_console(self):
        self.manager["run"] = lambda *args, **kwargs: SimpleNamespace(
            returncode=0, stdout="2026-09-24T08:02:00Z game server started\n")
        self.manager["audit_event"]("Changed player role")
        dock = self.original_activity_text("dock")
        self.assertIn("Changed player role", dock)
        self.assertIn("game server started", dock)

    def test_chat_bridge_only_sends_validated_chat_action(self):
        sent = []

        class FakeConnection:
            replied = False
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def settimeout(self, _):
                pass

            def sendall(self, data):
                sent.append(json.loads(data))

            def recv(self, _):
                if self.replied:
                    return b''
                self.replied = True
                return b'{"ok":true}\n'

        with mock.patch.object(self.manager["socket"], "create_connection", return_value=FakeConnection()):
            self.manager["send_chat"]("Hello players")
        self.assertEqual(sent[0]["action"], "chat")
        self.assertEqual(sent[0]["message"], "Hello players")
        with self.assertRaises(ValueError):
            self.manager["send_chat"]("bad\nmessage")

    def test_backups_can_be_downloaded_but_paths_cannot_escape(self):
        headers = {}
        responses = []
        self.handler.wfile = io.BytesIO()
        self.handler.send_response = responses.append
        self.handler.send_header = lambda key, value: headers.update({key: value})
        self.handler.end_headers = lambda: None
        archive = "openrct2-20260924T080000Z.tar.gz"
        self.manager["BACKUPS"].joinpath(archive).write_bytes(b"archive")
        self.handler.download_backup(archive)
        self.assertEqual(responses[-1], 200)
        self.assertEqual(self.handler.wfile.getvalue(), b"archive")
        self.assertIn("attachment", headers["Content-Disposition"])
        self.handler.wfile = io.BytesIO()
        self.handler.download_backup("../web-credentials")
        self.assertEqual(responses[-1], 404)

        snapshot = "manager-snapshot-20260924T080000Z.park"
        self.manager["SAVES"].joinpath(snapshot).write_bytes(b"park")
        self.handler.wfile = io.BytesIO()
        self.handler.download_snapshot(snapshot)
        self.assertEqual(responses[-1], 200)
        self.assertEqual(self.handler.wfile.getvalue(), b"park")


if __name__ == "__main__":
    unittest.main()
