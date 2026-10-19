# DJF-Windows 实体键盘输入

USB 机械键盘继续直接插 Windows 机箱：

- 没有已连接的 djf RDP 会话时，键盘由 Windows 原样处理，操作实体显示器上的本地桌面。
- DJF-Windows 的 djf RDP 会话连接并进入桌面时，`DJF-Windows-Physical-Keyboard` 把实体键盘输入送到该 RDP 桌面的当前输入位置，阻止同一次按键落到本地登录画面。
- RDP 断开、注销或锁定时停止转发，并释放本组件按下的键。重新连接后自动恢复，不自动登录、解锁或搬移 Windows 会话。

该组件只处理主机上的实体键盘。它过滤注入事件，保留扫描码、左右修饰键、按下/松开和重复输入；转发使用独立标记，实体 Ctrl+X 仍为剪切。Mac 的键鼠路由、拖动间隔、四指切换、豆包和剪贴板组件无需更新。

实现：`PhysicalKeyboard.cs` 的 SYSTEM 任务仅在当前用户存在已连接 RDP 会话时启动一对无窗口进程。控制台 Winlogon 桌面接收实体键盘，RDP Default 桌面注入输入，二者使用仅 SYSTEM 可访问的本机命名管道。进程不记录按键值或文字，不开放网络端口，不安装键盘驱动，也不修改 RDP、登录或安全策略。

部署：将 `PhysicalKeyboard.cs`、`Tests/PhysicalKeyboardChecks.cs`、`TrackpadBridge/DeleteShortcut.cs` 和 `install-physical-keyboard.ps1` 放到当前用户的 `%LOCALAPPDATA%\DJF-Windows\updates\physical-keyboard-1.0`，以该用户的管理员权限执行安装脚本。脚本先编译并运行检查，再将唯一运行程序安装到 `C:\ProgramData\DJF-Windows\PhysicalKeyboard`，由 SYSTEM 启动任务运行。程序目录仅允许 SYSTEM 和管理员写入。

诊断文件位于该目录的 `broker.json`、`capture.json`、`receive.json`，仅包含会话、进程、状态和事件计数。没有 RDP 时应为 `mode=console`，捕获/接收进程均为 0。RDP 实测必须同时确认真实 USB 按键在所见输入框出现，不能只凭进程运行或设备状态判定成功。

2026-10-19 已部署到 DJF-Windows。用户实测确认机械键盘可在 RDP 中输入、使用 Shift 和删除；断开 RDP 后，在实体显示器上登录并输入、删除也正常。控制台模式无键盘钩子，RDP 模式实体发送和接收计数相符，松开后无残留按键。Windows App 连接曾卡在其剪贴板初始化，退出并重启该客户端后恢复，未更改连接配置。
