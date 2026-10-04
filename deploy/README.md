# Future split-process wrapper

These templates describe the next split-process deployment, not the currently
installed compatibility service. Use them only after the `openrct2_manager.web`
ASGI application and `openrct2_manager.worker` entry point are installed in
`/opt/openrct2-manager/venv`. They intentionally run as separate processes: HTTP/SSE requests
only validate and enqueue work; the worker owns archive generation, hashing and remote transfer.

Use one Uvicorn worker while sessions and SSE fan-out are process-local. Horizontal web workers
require moving sessions, event fan-out and rate limits to a shared service such as Redis first.
The game has `Wants=`/`After=` dependencies on the manager, not `Requires=` or `BindsTo=`, so a
portal upgrade or restart does not disconnect players. The plug-in callback outbox tolerates either
service being temporarily unavailable.

Before enabling the units, create `/etc/openrct2-manager/manager.env` mode `0640`, owned by
`root:openrct2-manager`; create the declared writable directories; run the database migration; and
verify the loopback health endpoint. Validate with `systemd-analyze verify` and `caddy validate`.
