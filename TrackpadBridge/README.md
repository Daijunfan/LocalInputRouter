# Native trackpad bridge

Receiver 1.1.1 retains the original native touchpad implementation and adds the authenticated `delete` message. Its handshake advertises `deleteKey`; old clients remain supported. Windows App handles the native RDP pointer without a second cursor window.

The Mac router and Windows physical-mouse utility are independent.

- `ContactSource.m`: isolates the private macOS MultitouchSupport ABI; captures up to five contacts from the built-in trackpad. Raw positions are used only in memory and in the encrypted input stream.
- `TrackpadBridge.swift`: authenticated newline-JSON stream through an SSH local forward (`127.0.0.1:24801`). Frame data includes stable finger identities and normalized positions. No clipboard or typed text is carried by this channel.
- `NativeTouchpad.cs` / `Receiver.cs`: Windows session process creates a `PT_TOUCHPAD` device using `CreateSyntheticPointerDevice2` with physical dimensions and `SDCO_TOUCHPAD_GESTURE_ONLY`. Windows recognizes continuous multi-finger gestures. Discrete three/four/five-finger taps use `InjectTouchpadAction`.
- Deskflow continues to forward keys, pointer motion and ordinary mouse-button events.
- In 1.4.1, continuous two-finger scroll events use Mac-computed point deltas, including its acceleration and momentum, through the authenticated channel. `NativeScroll.cs` injects fine wheel units with fractional carry. A separate scroll multiplier defaults to 1.50 and accepts 0.10–10.00 with two decimals. Windows applications control how wheel input is rendered; do not claim identical frame rate or pixel distance across applications.
- During two-contact input the native pair's centroid is fixed while relative contact separation is preserved, so native pinch/rotation stays available without a duplicate native pan. Contact-count transitions cancel the previous pair before restarting the native contacts. Three/four-finger input remains native.
- Old clients retain native panning. The `macScroll` handshake capability enables the new path; if absent, the Mac keeps the legacy native pan path.

The receiver listens only on Windows loopback. A per-user secret authenticates connections; it is stored outside this workspace in the Mac app support directory and Windows user app-data folder. Never include the token in logs, repository files or app bundles.

Deployment: `DJF-Windows-Native-Trackpad` is a scheduled interactive task for `djf`, with highest privileges and a logon trigger. The existing `Deskflow` service must stay running/automatic. Do not stop it when maintaining the independent physical-mouse EXE.

Reset and disconnection cancel active contacts. The receiver destroys the synthetic device when the authenticated connection closes. A receive timeout covers lost connections. Mac emergency return stops capture and closes the channel along with the keyboard/mouse tunnel.

API references:
- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createsyntheticpointerdevice2
- https://learn.microsoft.com/en-us/windows/win32/api/winuser/ne-winuser-synthetic_device_creation_options
- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-injecttouchpadaction
- https://learn.microsoft.com/en-us/windows/win32/input-precisiontouchpad/precision-touchpad-portal
- macOS ABI reference: https://github.com/lauschue/Remotastic/blob/main/MultitouchSupport.h

Verification completed on 2026-10-06: Windows 11 build 26200.9457 exports the native APIs; interactive-session device creation, single-contact injection/cancel, two/five-contact input/cancel, SSH authentication and heartbeat passed. Built-in Mac trackpad capture reported a 156 × 96 mm surface and live frames. App UI and runtime confirm the native channel is connected. Real gesture behavior and smoothness require the user's hardware trial; do not infer it from successful injection alone.

Windows behavior is used for native gestures. Zoom/rotation/page gestures depend on the target application. macOS-specific Force Touch lookup and Launchpad are not promised as equivalent Windows functions.

Build the receiver with all three production sources, using .NET Framework `csc.exe`:

```powershell
csc.exe /target:winexe /r:System.Web.Extensions.dll /out:TrackpadReceiver.exe NativeTouchpad.cs NativeScroll.cs Receiver.cs
```

`ScrollChecks.cs` + `NativeScroll.cs` run pure conversion checks without injecting input. Mac `InputRouter/PrecisionChecks.swift` checks gain, momentum forwarding and local-input isolation without taking over input. 1.4.1 installation verified the new capability, UI input/apply, and an authenticated receiver in the user desktop session. Physical scrolling/pinch acceptance is pending user feedback.
# Windows 接收端 1.1.1

三指左右滑动在 Windows 接收端转换为四指原生触控输入，沿用 Windows 原有桌面切换。三指纵向、三指轻点与真正四指输入保留各自行为。识别只保存开始帧，方向确定后继续原生注入，不增加持续帧缓冲。

Mac Command 已由原路由映射为 Windows Ctrl。本接收端把路由注入的 Ctrl+Backspace／Ctrl+X 转为普通 Delete，并接受 Mac 前台 DJF-Windows 窗口的认证 Delete 请求；发送 Delete 前临时释放该路由 Ctrl，随后恢复，并成对发送按下/松开。Windows 实体键盘的 Ctrl+Backspace、其他修饰键组合及语音文字注入保留原用途。

部署源码：`Receiver.cs`、`NativeTouchpad.cs`、`NativeScroll.cs`、`ThreeFingerDesktop.cs`、`DeleteShortcut.cs`、`RoutedKeyboard.cs`。将这些文件及 `WindowsBindingsChecks.cs` 放到 Windows `%LOCALAPPDATA%\DJF-Windows\updates\receiver-1.1.1`，执行 `install-windows-bindings.ps1`。脚本先编译并运行检查，再更新当前接收端，复用原有登录任务。安装不修改 Mac 程序或设置。

已通过纯映射检查及原生低级按键测试；测试器拦住 Delete，确保不删除用户文件。详细结果见项目根目录 `verification.json`。
