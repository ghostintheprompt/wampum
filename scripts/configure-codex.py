#!/usr/bin/env python3
"""Register this checkout's local MCP helper in the Codex project config.
No global client settings, provider credentials, or Wampum sharing grants change.
"""
import json
import os
import pathlib
import tomllib

root = pathlib.Path(__file__).resolve().parent.parent
helper = root / 'build/Wampum.app/Contents/MacOS/WampumController'
if not helper.is_file():
    raise SystemExit('Build Wampum first with scripts/build-app.sh')
state = pathlib.Path.home() / 'Library/Application Support/Wampum'
entry = {'command': str(helper), 'args': ['--state-dir', str(state)]}
codex_file = root / '.codex/config.toml'
codex_source = codex_file.read_text() if codex_file.exists() else ''
codex = tomllib.loads(codex_source)
existing = codex.get('mcp_servers', {}).get('wampum')
if existing is not None and existing != entry:
    raise SystemExit('Existing project Codex wampum entry differs; review it manually. No file changed.')
if existing is None:
    codex_file.parent.mkdir(mode=0o700, exist_ok=True)
    addition = '\n[mcp_servers.wampum]\ncommand = ' + json.dumps(str(helper)) + '\nargs = ' + json.dumps(entry['args']) + '\n'
    codex_file.write_text(codex_source + addition)
    os.chmod(codex_file, 0o600)
print('Wampum Codex project MCP connection prepared. Sharing remains off in the app.')
