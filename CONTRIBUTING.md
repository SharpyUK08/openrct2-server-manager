# Contributing

Thanks for helping make private OpenRCT2 servers easier to run.

1. Keep changes small and explain the operator-visible effect, especially if a change restarts the game or touches saved data.
2. Run `bash -n outputs/install-openrct2-manager.sh` and `python3 -m unittest discover -s tests -v` before proposing a change.
3. Check any OpenRCT2 scripting calls against the versioned upstream API. The helper currently targets v0.5.5 / API 122.
4. Do not add public admin sockets, unrestricted web consoles, or silent destructive cleanup.
5. Update the README and security notes when behaviour, ports, backups or permissions change.

For local UI work, `python3 tests/preview_manager.py` serves sample data on `127.0.0.1:8765` without authentication. Never bind this preview to a public address. `python3 tests/preview_manager.py --static` also generates standalone sample pages in a temporary directory.

The current installer is intentionally self-contained for easy setup on a fresh Ubuntu server. Pull requests that separate components are welcome if they retain a straightforward installation and upgrade path.
