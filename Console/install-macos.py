#!/usr/bin/env python3
"""Add console video to the existing desktop tunnel, independent of input capture."""
from pathlib import Path
import os
import subprocess

installed = Path.home() / '.local/share/djf-windows/rdp-direct-tunnel.py'
paths = [installed, Path.home() / 'develop/MyWin/rdp-direct-tunnel.py']
old = "'-L', '127.0.0.1:23389:127.0.0.1:3389', 'djf@' + address"
new = "'-L', '127.0.0.1:23389:127.0.0.1:3389',\n    '-L', '127.0.0.1:24805:127.0.0.1:24805', 'djf@' + address"
for path in paths:
    if not path.exists():
        if path == installed:
            raise SystemExit('The existing DJF-Windows desktop tunnel is not installed.')
        continue
    text = path.read_text()
    if '127.0.0.1:24805:127.0.0.1:24805' not in text:
        if old not in text:
            raise SystemExit(f'The existing desktop tunnel needs review: {path}')
        path.write_text(text.replace(old, new))
subprocess.run(['launchctl', 'kickstart', '-k', f'gui/{os.getuid()}/com.djf.windows-rdp'], check=True)
print('Console video uses the existing DJF-Windows desktop tunnel.')
