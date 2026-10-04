"""Local-only sample-data preview for reviewing the web interface."""

import json
import io
import sys
import tempfile
from http.server import ThreadingHTTPServer
from pathlib import Path

from test_manager import load_manager


def main():
    manager = load_manager()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        if "--setup-static" in sys.argv:
            for name in ("SETUP_STATE", "PORTAL_USERS", "CREDENTIALS", "CONFIG_INI"):
                manager[name] = root / name.lower()
            manager["CREDENTIALS"].write_text("admin:preview-only-password\n")
            manager["CONFIG_INI"].write_text(
                '[network]\nserver_name="My OpenRCT2 Server"\nserver_description=""\nserver_greeting=""\n'
                'maxplayers=16\ndefault_port=11753\nadvertise=true\nadvertise_address=""\n'
                'pause_server_if_no_clients=true\ndefault_password=""\n[general]\nautosave=1\nautosave_amount=10\n')
            manager["initialize_setup_token"]("preview-one-time-password")
            manager["detected_openrct2"] = lambda: {
                "path": "/usr/bin/openrct2-cli", "version": "OpenRCT2, v0.5.5", "healthy": True}
            handler = object.__new__(manager["Handler"]); handler.wfile = io.BytesIO()
            handler.send_response = lambda *_: None; handler.send_header = lambda *_: None
            handler.end_headers = lambda: None; handler.setup_page()
            output = Path(tempfile.mkdtemp(prefix="openrct2-setup-preview-"))
            output.joinpath("setup.html").write_bytes(handler.wfile.getvalue().replace(b'/logo.svg', b'logo.svg'))
            output.joinpath("logo.svg").write_text(manager["LOGO_SVG"])
            print(output / "setup.html", flush=True); return
        for name in ("SCENARIOS", "BACKUPS", "SAVES"):
            folder = root / name.lower()
            folder.mkdir()
            manager[name] = folder
        for name in ("SELECTED", "USERS_JSON", "SETTINGS", "HELPER", "CONTROL_TOKEN_FILE", "AUDIT_LOG"):
            manager[name] = root / name.lower()
        manager["ensure_control_token"]()
        for name in ("Mountain Sandbox.park", "Forest Valley.park", "Blank Slate.sc6"):
            (manager["SCENARIOS"] / name).write_bytes(b"preview")
        manager["SELECTED"].write_text("Mountain Sandbox.park")
        manager["USERS_JSON"].write_text(json.dumps([
            {"name": "samsharpe", "hash": "a" * 40, "groupId": 0},
            {"name": "Partner", "hash": "b" * 40, "groupId": 2},
        ]))
        manager["SAVES"].joinpath("manager-snapshot-20260924T080000Z.park").write_bytes(b"preview")
        manager["BACKUPS"].joinpath("openrct2-20260924T080000Z.tar.gz").write_bytes(b"preview")
        manager["service_active"] = lambda: True
        manager["activity_text"] = lambda mode="chat": (
            "2026-09-24T08:00:00Z MANAGER Launched park Mountain Sandbox.park\n"
            "2026-09-24T08:02:00Z [CHAT] Partner: Hello!"
        )
        manager["Handler"].authenticated = lambda self: True
        if "--static" in sys.argv:
            output = Path(tempfile.mkdtemp(prefix="openrct2-preview-"))
            logo = Path(__file__).resolve().parents[1] / "outputs" / "openrct2-manager-logo.svg"
            output.joinpath("logo.svg").write_bytes(logo.read_bytes())
            for tab in ("overview", "parks", "players", "backups", "activity", "settings"):
                handler = object.__new__(manager["Handler"])
                handler.path = "/?tab=" + tab
                handler.wfile = io.BytesIO()
                handler.send_response = lambda *_: None
                handler.send_header = lambda *_: None
                handler.end_headers = lambda: None
                handler.dashboard("", tab)
                output.joinpath(tab + ".html").write_bytes(
                    handler.wfile.getvalue().replace(b"/logo.svg", b"logo.svg"))
            print(output, flush=True)
            return
        print("Preview at http://127.0.0.1:8765/", flush=True)
        ThreadingHTTPServer(("127.0.0.1", 8765), manager["Handler"]).serve_forever()


if __name__ == "__main__":
    main()
