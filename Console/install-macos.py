#!/usr/bin/env python3
"""Add console video to the existing desktop tunnel, independent of input capture."""
from pathlib import Path
import os
import subprocess

installed = Path.home() / '.local/share/djf-windows/rdp-direct-tunnel.py'
paths = [installed, Path.home() / 'develop/MyWin/rdp-direct-tunnel.py']
rdp = "'-L', '127.0.0.1:23389:127.0.0.1:3389',"
old = "'-L', '127.0.0.1:24805:127.0.0.1:24805',"
new = "'-L', '127.0.0.1:24905:127.0.0.1:24905',"
for path in paths:
    if not path.exists():
        if path == installed:
            raise SystemExit('The existing DJF-Windows desktop tunnel is not installed.')
        continue
    text = path.read_text()
    updated = text.replace(old, new)
    if new not in updated:
        if rdp not in updated:
            raise SystemExit(f'The existing desktop tunnel needs review: {path}')
        updated = updated.replace(rdp, rdp + '\n    ' + new, 1)
    if updated != text:
        path.write_text(updated)
subprocess.run(['launchctl', 'kickstart', '-k', f'gui/{os.getuid()}/com.djf.windows-rdp'], check=True)
print('Console video uses loopback port 24905; RDP remains on 23389.')
