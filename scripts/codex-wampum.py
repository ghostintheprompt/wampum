#!/usr/bin/env python3
"""Launch Codex with Wampum configured for this invocation, without global edits."""
import json
import os
import pathlib
import sys
root = pathlib.Path(__file__).resolve().parent.parent
helper = root / 'build/Wampum.app/Contents/MacOS/WampumController'
if not helper.is_file():
    raise SystemExit('Build Wampum first with scripts/build-app.sh')
state = pathlib.Path.home() / 'Library/Application Support/Wampum'
arguments = ['codex', '-C', str(root), '-c', 'mcp_servers.wampum.command=' + json.dumps(str(helper)), '-c', 'mcp_servers.wampum.args=' + json.dumps(['--state-dir', str(state)])] + sys.argv[1:]
os.execvp('codex', arguments)
