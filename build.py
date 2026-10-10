#!/usr/bin/env python3
"""Build the independent Mac input router from its own sources."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

root=Path(__file__).resolve().parent
source=root/'Mac'
deskflow=Path('/Applications/Deskflow.app')
if not (deskflow/'Contents/MacOS/deskflow-core').is_file():
    raise SystemExit('Install Deskflow for Mac before building Input Router.')
sys.path.insert(0,str(source))
from signing import sign

output=root/'build'
bundle=output/'Input Router.app'
if bundle.exists():shutil.rmtree(bundle)
macos=bundle/'Contents/MacOS'
resources=bundle/'Contents/Resources'
helpers=bundle/'Contents/Helpers'
for folder in (macos,resources,helpers):folder.mkdir(parents=True)
sources=[source/(name+'.swift') for name in
    ('Shortcut','InputControl','TapDrag','ThreeFingerDoubleTap','GestureFrameGate',
     'LocalCursor','RouterController','App','AgentApp','Entry','Checks','TrackpadBridge',
     'VoiceTextView','VoiceBridge','VoiceTransport','MacVoiceEvents','ClipboardBridge','ToolWindow')]
contact=output/'ContactSource.o'
cursor=output/'Cursor.o'
subprocess.run(['clang','-O2','-c',str(source/'ContactSource.m'),'-o',str(contact)],check=True)
subprocess.run(['clang','-O2','-c',str(source/'Cursor.c'),'-o',str(cursor)],check=True)
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O',*(str(p) for p in sources),
    str(contact),str(cursor),'-import-objc-header',str(source/'Bridging.h'),
    '-o',str(macos/'InputRouter'),'-framework','AppKit','-framework','SwiftUI',
    '-framework','ApplicationServices','-framework','Carbon','-framework','Network',
    '-framework','IOKit','-framework','Security'],check=True)
subprocess.run(['swiftc','-O',str(source/'BluetoothPipe.swift'),'-framework','IOBluetooth',
    '-o',str(helpers/'BluetoothPipe')],check=True)
sign(helpers/'BluetoothPipe')

icon=source/'AppIcon.png'
iconset=output/'AppIcon.iconset';iconset.mkdir(exist_ok=True)
for size in (16,32,128,256,512):
    for scale in (1,2):
        filename=f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png'
        subprocess.run(['sips','-z',str(size*scale),str(size*scale),str(icon),
            '--out',str(iconset/filename)],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(resources/'AppIcon.icns')],check=True)

# Deskflow is an externally installed GPL-2.0 program. Its binary is never in this repository.
shutil.copytree(deskflow,helpers/'Deskflow.app',symlinks=True)
shutil.copytree(deskflow/'Contents/Frameworks',bundle/'Contents/Frameworks',symlinks=True)
libraries=deskflow/'Contents/Libraries'
if libraries.exists():shutil.copytree(libraries,bundle/'Contents/Libraries',symlinks=True)
shutil.copy2(deskflow/'Contents/MacOS/deskflow-core',helpers/'InputRouterDeskflow')
sign(helpers/'InputRouterDeskflow',options='0')
subprocess.run(['clang','-dynamiclib','-O2',str(source/'VoicePassthrough.c'),
    '-framework','ApplicationServices','-o',str(helpers/'VoicePassthrough.dylib')],check=True)
sign(helpers/'VoicePassthrough.dylib')
with (bundle/'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier':'org.localinputrouter.app','CFBundleName':'Input Router',
        'CFBundleDisplayName':'输入路由','CFBundleExecutable':'InputRouter',
        'CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0',
        'CFBundleVersion':'1','CFBundleIconFile':'AppIcon','NSHighResolutionCapable':True,
        'NSPrincipalClass':'NSApplication',
        'NSBluetoothAlwaysUsageDescription':'连接已配对的 Windows 蓝牙设备以转发键盘和触控板。'},f)
sign(bundle)
subprocess.run(['codesign','--verify','--deep','--strict',str(bundle)],check=True)
print(bundle)
