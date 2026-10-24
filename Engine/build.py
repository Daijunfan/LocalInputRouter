#!/usr/bin/env python3
"""Build the native app and bundle the installed, signed Deskflow backend."""
from pathlib import Path
import argparse
import plistlib
import shutil
import subprocess
import os
from signing import sign

root = Path(__file__).resolve().parent
artifacts = root.parent / 'artifacts'
bundle = artifacts / 'DJF 输入路由.app'
parser = argparse.ArgumentParser()
parser.add_argument('--install', action='store_true')
args = parser.parse_args()
if bundle.exists():
    shutil.rmtree(bundle)
macos = bundle / 'Contents/MacOS'
resources = bundle / 'Contents/Resources'
helpers = bundle / 'Contents/Helpers'
for directory in [macos, resources, helpers]:
    directory.mkdir(parents=True)
sources = [root / (name + '.swift') for name in ['Shortcut', 'InputControl', 'TapDrag', 'ThreeFingerDoubleTap', 'GestureFrameGate', 'LocalCursor', 'RouterController', 'ConsoleDesktop', 'ConsoleWindow', 'App', 'AgentApp', 'Entry', 'Checks', 'TrackpadBridge', 'VoiceTextView', 'VoiceBridge', 'VoiceTransport', 'MacVoiceEvents', 'ClipboardBridge']]
sources.append(root.parent.parent / 'Shared/ToolWindow.swift')
sources.append(root.parent.parent / 'Shared/ToolDock.swift')
contact_source = root.parent / 'TrackpadBridge/ContactSource.m'
contact_object = artifacts / 'ContactSource.o'
subprocess.run(['clang', '-O2', '-c', str(contact_source), '-o', str(contact_object)], check=True)
cursor_object = artifacts / 'Cursor.o'
subprocess.run(['clang', '-O2', '-c', str(root / 'Cursor.c'), '-o', str(cursor_object)], check=True)
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O',
                *map(str, sources), str(contact_object), str(cursor_object), '-import-objc-header', str(root / 'Bridging.h'), '-o', str(macos / 'DJFInputRouter'),
                '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'ApplicationServices',
                '-framework', 'Carbon', '-framework', 'Network', '-framework', 'IOKit', '-framework', 'WebKit'], check=True)
subprocess.run(['swiftc', '-O', str(root / 'BluetoothPipe.swift'), '-framework', 'IOBluetooth',
                '-o', str(helpers / 'BluetoothPipe')], check=True)
sign(helpers / 'BluetoothPipe')
icon = root / 'AppIcon.png'
iconset = artifacts / 'InputRouter.iconset'
iconset.mkdir(exist_ok=True)
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        filename = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
        subprocess.run(['sips', '-z', str(size*scale), str(size*scale),
                        str(icon), '--out', str(iconset / filename)],
                       check=True, stdout=subprocess.DEVNULL)
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)
shutil.copy2(root.parent / 'deskflow-known-hosts', resources / 'known-hosts')
shutil.copy2(root.parent / 'Console/viewer.bundle.js', resources / 'console-viewer.js')
shutil.copy2(root.parent / 'Console/novnc/LICENSE.txt', resources / 'noVNC-LICENSE.txt')
shutil.copytree(root.parent / 'Console/novnc', resources / 'noVNC-source')
(resources / 'toolbox-integration').write_text('com.djf.toolbox\n')
shutil.copytree('/Applications/Deskflow.app', helpers / 'Deskflow.app', symlinks=True)
# The local backend adapter lives in our app; the installed vendor app stays intact.
shutil.copytree('/Applications/Deskflow.app/Contents/Frameworks', bundle / 'Contents/Frameworks', symlinks=True)
libraries = Path('/Applications/Deskflow.app/Contents/Libraries')
if libraries.exists():
    shutil.copytree(libraries, bundle / 'Contents/Libraries', symlinks=True)
shutil.copy2('/Applications/Deskflow.app/Contents/MacOS/deskflow-core', helpers / 'DJFDeskflow')
sign(helpers / 'DJFDeskflow', options='0')
subprocess.run(['clang', '-dynamiclib', '-O2', '-fblocks', str(root / 'VoicePassthrough.c'),
                '-framework', 'ApplicationServices', '-framework', 'Carbon', '-o', str(helpers / 'VoicePassthrough.dylib')], check=True)
sign(helpers / 'VoicePassthrough.dylib')
with (bundle / 'Contents/Info.plist').open('wb') as handle:
    plistlib.dump({'CFBundleIdentifier': 'com.djf.inputrouter', 'CFBundleName': 'DJF 输入路由',
        'CFBundleDisplayName': 'DJF 输入路由', 'CFBundleExecutable': 'DJFInputRouter',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.10.10',
        'CFBundleVersion': '55', 'CFBundleIconFile': 'AppIcon', 'NSHighResolutionCapable': True,
        'LSUIElement': True,
        'NSBluetoothAlwaysUsageDescription': '通过已配对的 DJF-Windows 蓝牙连接转发键盘与触控板，Mac 仍可连接校园 Wi-Fi。',
        'NSPrincipalClass': 'NSApplication'}, handle)
sign(bundle)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
# Keep one current build; archived app bundles become duplicate launch targets.
lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
old_apps = list(artifacts.rglob('*.app')) + list((root.parent.parent / 'artifacts').rglob('*.app'))
for old in old_apps:
    if old == bundle or old.is_symlink():
        continue
    try:
        info = plistlib.loads((old / 'Contents/Info.plist').read_bytes())
    except (OSError, plistlib.InvalidFileException):
        continue
    if info.get('CFBundleIdentifier') == 'com.djf.inputrouter':
        subprocess.run([lsregister, '-u', str(old)], capture_output=True)
        shutil.rmtree(old)
if args.install:
    target = Path('/Applications/DJF 输入路由.app')
    if target.exists():
        # Never replace a running installed binary.
        active = subprocess.run(['pgrep', '-f', str(target / 'Contents/MacOS/DJFInputRouter')], capture_output=True)
        if active.returncode == 0:
            raise SystemExit('Close the installed DJF input router before installing this build.')
        shutil.rmtree(target)
    shutil.copytree(bundle, target, symlinks=True)
    desktop = Path.home() / 'Desktop/DJF 输入路由.app'
    if not desktop.exists() and not desktop.is_symlink():
        desktop.symlink_to(target)
    label = 'com.djf.inputrouter.background'
    agent = Path.home() / f'Library/LaunchAgents/{label}.plist'
    support = Path.home() / 'Library/Application Support/DJF Input Router'
    agent.parent.mkdir(parents=True, exist_ok=True)
    support.mkdir(parents=True, exist_ok=True)
    # Login launch and abnormal-exit recovery; explicit Quit (exit 0) stays quit.
    agent.write_bytes(plistlib.dumps({
        'Label': label,
        'ProgramArguments': [str(target / 'Contents/MacOS/DJFInputRouter'), '--background'],
        'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False},
        'ThrottleInterval': 1, 'ProcessType': 'Interactive',
        'StandardOutPath': str(support / 'app.log'),
        'StandardErrorPath': str(support / 'app-error.log'),
    }))
    domain = f'gui/{os.getuid()}'
    subprocess.run(['launchctl', 'bootout', f'{domain}/{label}'], capture_output=True)
    subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
    subprocess.run([lsregister, '-f', str(target)], capture_output=True)
    subprocess.run([lsregister, '-u', str(bundle)], capture_output=True)
    shutil.rmtree(bundle)
    print(target)
else:
    print(bundle)
