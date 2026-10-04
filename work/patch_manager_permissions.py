#!/usr/bin/env python3
from pathlib import Path

path = Path('/usr/local/lib/openrct2-manager.py')
source = path.read_text()
if "USERS_JSON = Path('/var/lib/openrct2/user-data/users.json')" in source:
    print('Permissions UI is already installed.')
    raise SystemExit(0)

changes = [
    (
        'import html\nimport os\n',
        'import html\nimport json\nimport os\n',
    ),
    (
        "ENV_FILE = Path('/etc/openrct2-manager/server.env')\nALLOWED = {'.park', '.sv6', '.sc6'}\nCSRF = secrets.token_urlsafe(32)\n",
        "ENV_FILE = Path('/etc/openrct2-manager/server.env')\nUSERS_JSON = Path('/var/lib/openrct2/user-data/users.json')\nALLOWED = {'.park', '.sv6', '.sc6'}\nCSRF = secrets.token_urlsafe(32)\nROLES = {0: 'Administrator', 1: 'Spectator', 2: 'Player'}\n",
    ),
    (
        "def selected_name():\n",
        '''def user_roles():
    try:
        data = json.loads(USERS_JSON.read_text())
        if not isinstance(data, list):
            return []
        return [item for item in data if isinstance(item, dict) and isinstance(item.get('name'), str)]
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return []

def write_user_roles(users):
    USERS_JSON.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', dir=USERS_JSON.parent, prefix='.users-', delete=False) as temp:
        json.dump(users, temp, indent=4, ensure_ascii=False)
        temp.write('\\n')
        temp_path = Path(temp.name)
    try:
        os.chmod(temp_path, 0o640)
        os.replace(temp_path, USERS_JSON)
    finally:
        temp_path.unlink(missing_ok=True)

def role_name(group_id):
    return ROLES.get(group_id, f'Group {group_id}')

def selected_name():
''',
    ),
    (
        "            elif self.path == '/select':\n                self.select(fields)\n            elif self.path == '/action':\n",
        "            elif self.path == '/select':\n                self.select(fields)\n            elif self.path == '/permissions':\n                self.permissions(fields)\n            elif self.path == '/action':\n",
    ),
    (
        "    def action(self, fields):\n",
        '''    def permissions(self, fields):
        player = fields.get('player', '').strip()
        if not player or len(player) > 32 or any(ord(char) < 32 for char in player):
            raise ValueError('Enter the exact in-game player name (1–32 characters).')
        try:
            group_id = int(fields.get('role', ''))
        except ValueError:
            raise ValueError('Choose a valid role.')
        if group_id not in ROLES:
            raise ValueError('Choose a valid role.')

        was_active = service_active()
        if was_active:
            result = run('/usr/bin/sudo', '/usr/bin/systemctl', 'stop', 'openrct2.service', timeout=75)
            if result.returncode:
                raise ValueError(result.stderr.strip() or 'Could not pause the game server.')
        try:
            users = user_roles()
            match = next((item for item in users if item.get('name', '').casefold() == player.casefold()), None)
            if match is None:
                users.append({'groupId': group_id, 'hash': '', 'name': player})
            else:
                match['name'] = player
                match['groupId'] = group_id
                match.setdefault('hash', '')
            write_user_roles(users)
        except Exception:
            if was_active:
                run('/usr/bin/sudo', '/usr/bin/systemctl', 'start', 'openrct2.service', timeout=75)
            raise
        if was_active:
            result = run('/usr/bin/sudo', '/usr/bin/systemctl', 'start', 'openrct2.service', timeout=75)
            if result.returncode:
                raise ValueError(result.stderr.strip() or 'Role saved, but the game server could not restart.')
        suffix = ' The game server was restarted.' if was_active else ''
        self.redirect(f'{player} is now {ROLES[group_id]}.{suffix}')

    def action(self, fields):
''',
    ),
    (
        "        backups = backup_files()\n",
        "        backups = backup_files()\n        users = user_roles()\n",
    ),
    (
        "        notice = f'<div class=\"notice\">{html.escape(message)}</div>' if message else ''\n",
        '''        user_rows = ''.join(
            f'<tr><td>{html.escape(item.get("name", ""))}</td><td>{html.escape(role_name(item.get("groupId")))}</td></tr>'
            for item in sorted(users, key=lambda item: item.get('name', '').casefold())
        ) or '<tr><td colspan="2" class="muted">No saved player roles yet.</td></tr>'
        notice = f'<div class="notice">{html.escape(message)}</div>' if message else ''
''',
    ),
    (
        ".notice{{padding:12px 15px;background:#dff3e8;border-left:4px solid var(--green);border-radius:5px}}.muted,small{{color:var(--muted)}}ul{{padding-left:20px;margin-bottom:0}}li{{margin:7px 0}}li span{{color:var(--muted);margin-left:6px}}code{{background:#edf0f5;padding:2px 5px;border-radius:4px}}.check{{margin-top:10px;font-weight:400}}@media(max-width:560px){{.status{{align-items:flex-start;flex-direction:column}}}}\n",
        ".notice{{padding:12px 15px;background:#dff3e8;border-left:4px solid var(--green);border-radius:5px}}.muted,small{{color:var(--muted)}}ul{{padding-left:20px;margin-bottom:0}}li{{margin:7px 0}}li span{{color:var(--muted);margin-left:6px}}code{{background:#edf0f5;padding:2px 5px;border-radius:4px}}.check{{margin-top:10px;font-weight:400}}@media(max-width:560px){{.status{{align-items:flex-start;flex-direction:column}}}}\ntable{{width:100%;border-collapse:collapse;margin-top:15px}}th,td{{padding:9px 10px;border-bottom:1px solid #e2e8f0;text-align:left}}th{{color:var(--muted);font-size:.88rem}}.hint{{margin:0 0 14px;color:var(--muted)}}\n",
    ),
    (
        '<section class="card"><h2>Backups</h2>',
        '<section class="card"><h2>Player permissions</h2><p class="hint">Use the player\'s exact OpenRCT2 name. Administrator has full control, Player can build, and Spectator is view-only.</p><form method="post" action="/permissions"><input type="hidden" name="csrf" value="{CSRF}"><label for="player">Player name</label><input id="player" name="player" maxlength="32" required placeholder="Exact in-game name"><label for="role" style="margin-top:12px">Role</label><select id="role" name="role"><option value="2">Player — can build</option><option value="0">Administrator — full control</option><option value="1">Spectator — view only</option></select><div class="buttons"><button>Save role</button></div></form><small>Applying a role briefly restarts a running server.</small><table><thead><tr><th>Saved player</th><th>Role</th></tr></thead><tbody>{user_rows}</tbody></table></section>\n<section class="card"><h2>Backups</h2>',
    ),
]

for old, new in changes:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'Expected exactly one match, found {count}: {old[:80]!r}')
    source = source.replace(old, new, 1)

compile(source, str(path), 'exec')
backup = path.with_suffix('.py.pre-permissions')
if not backup.exists():
    backup.write_text(path.read_text())
path.write_text(source)
path.chmod(0o755)
print('Permissions UI installed and syntax checked.')
