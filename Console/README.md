# DJF-Windows 共享实体桌面

在输入路由 App 中点击「连接共享实体桌面」。它把现有 djf 桌面接回实体控制台，保留正在运行的应用；Mac 查看器与接在机箱上的 USB 键盘操作同一个桌面。首次登录前可显示控制台的 Windows 登录画面。

查看器内置在唯一的输入路由 App 中，复用设备密钥自动认证，不打开屏幕共享、钥匙串或密码窗口。启动、四指切换和后台检查都不创建新的桌面窗口；用户主动点击连接才创建。四指切换可激活用户已经打开的桌面窗口，普通窗口点击不会启用输入路由。

Windows App 的 RDP 独立会话继续保留。机箱 USB 键盘也可通过独立 [实体键盘组件](../Windows/README.md) 输入到当前 RDP 桌面；没有 RDP 时保留本地控制台输入。重新连接传统 RDP 会把用户桌面接回 RDP 会话。

画面使用已有独立桌面 SSH 隧道的回环端口 24905，Windows TightVNC 也仅监听 127.0.0.1:24905；RDP 仍使用 Mac 端口 23389。24805 留给文件快传的本机服务及反向隧道，避免视频转发绑定失败导致整个 RDP 隧道退出。桌面隧道独立于键鼠路由暂停、退出及安全输入状态。VNC 启用独立认证、允许本地键盘输入，不添加防火墙入口；认证密码从已有设备密钥派生，不使用 Windows 登录密码。

无 HDMI 时使用已签名的 Virtual Display Driver 提供 1920×1080 画面。`DJF-Windows-Console-Display` 是 Windows 本机的 SYSTEM 开机任务，直接运行 `ConsoleDisplay.exe`，不依赖 Mac、SSH、网络或 PowerShell 常驻。工作进程跟随实体控制台，登录前与 RDP 连接期间均可检查 `QueryDisplayConfig` 的实际输出；实体屏缺失时保留已有显示路径和模式，只补上可用的实体输出。虚拟与 RDP 显示器按适配器身份区分，不再因插入 HDMI 停用虚拟设备。安装时恢复旧守护停用的虚拟设备。

实体屏接入时，控制台工作进程申请 `ES_DISPLAY_REQUIRED`，避免 RDP 中的输入无法唤醒实体锁屏、显示器自动关屏；拔掉实体屏后释放请求。开机或热插拔时向驱动重新下发模式，避免已标记启用的 HDMI 通道停留在黑屏状态。实体屏作为主屏显示本地登录和锁屏，虚拟屏的分辨率和屏幕间相对位置保持不变。它不改电源计划、系统睡眠、屏保、显卡驱动或全局 PowerShell 策略。任务有开机触发、每分钟检查及进程失败重启；`broker.json` 和 `display-status.json` 记录控制台会话、实际显示通道、修复次数与心跳。

源码与部署：`install.ps1` 安装官方签名 TightVNC；`ConsoleDesktop.ps1` 校验 DJF 主机并连接现有控制台；`install-display.ps1` 部署签名显示驱动；`install-display-agent.ps1` 编译并安装自动显示任务；`install-macos.py` 为已有独立桌面隧道增加画面转发。设备认证配置沿用现有每用户目录。PowerShell 的 RemoteSigned 仅作用于这些子进程。

从旧端口升级时，在 DJF-Windows 以管理员权限执行 `migrate-video-port.ps1`，然后在 Mac 执行 `python3 Console/install-macos.py` 并安装 1.10.2 App。迁移只改已有 VNC 服务的监听端口，保留认证和输入配置；无需重启 Windows。Mac 安装脚本兼容旧视频转发与仅有 RDP 的配置，重复执行不会增加重复转发。

查看器复用项目已有 noVNC 1.7.0，保留 MPL-2.0 许可。此副本不请求客户端光标编码，由 Windows 在画面中绘制一个光标，避免已路由时 Mac 光标被冻结而远端光标消失。构建 JS：

```sh
esbuild Console/viewer.js --bundle --minify --format=esm --outfile=Console/viewer.bundle.js
```

`DJFInputRouter --console-check` 在隐藏的同一生产查看器中完成认证及真实帧解码，结果位于 App 数据目录的 `console-check.json`。只记录分辨率及非黑像素采样数量，不保存画面、密码或桌面文字。

当前已验证：djf 为实体控制台 Session 2；无物理显示器时虚拟显示正常；实际 1920×1080 帧解码通过；本地输入允许，USB HID 设备健康。2026-10-19 用户已实测确认机箱 USB 机械键盘在 RDP 和实体显示器中均可输入、删除。HDMI 插拔和共享查看器的实际手感仍需现场确认。

显示守护升级：将 `ConsoleDisplay.cs`、兼容入口 `ConsoleDisplay.ps1` 与 `install-display-agent.ps1` 放在同一目录，在 DJF-Windows 的管理员 PowerShell 中执行安装脚本。`-Observe` 仅记录显示通道，不启用修复或恢复虚拟设备。策略和 Win32 结构布局由 `Tests/ConsoleDisplayChecks.cs` 在 Windows 的 .NET Framework 编译器下验证。

2026-10-24 软件侧验证：Windows 编译与策略检查通过；已确认用户重启后的任务自动启动、实体主屏与虚拟屏共同启用、工作进程退出后自动恢复。实体面板实际亮屏仍未通过现场确认，不能用 API 的启用状态代替这一项验收。
