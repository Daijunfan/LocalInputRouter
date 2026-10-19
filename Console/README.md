# DJF-Windows 共享实体桌面

在输入路由 App 中点击「连接共享实体桌面」。它把现有 djf 桌面接回实体控制台，保留正在运行的应用；Mac 查看器与接在机箱上的 USB 键盘操作同一个桌面。首次登录前可显示控制台的 Windows 登录画面。

查看器内置在唯一的输入路由 App 中，复用设备密钥自动认证，不打开屏幕共享、钥匙串或密码窗口。启动、四指切换和后台检查都不创建新的桌面窗口；用户主动点击连接才创建。四指切换可激活用户已经打开的桌面窗口，普通窗口点击不会启用输入路由。

Windows App 的 RDP 独立会话继续保留。USB 键盘与远程画面共用时使用共享实体桌面入口；重新连接传统 RDP 会把用户桌面接回 RDP 会话。

画面使用已有独立桌面 SSH 隧道的回环端口 24805，独立于键鼠路由暂停、退出及安全输入状态。Windows TightVNC 仅监听 127.0.0.1，启用独立 VNC 认证，允许本地键盘输入，不添加防火墙入口。认证密码从已有设备密钥派生，仅用于此通道，不使用 Windows 登录密码。

无 HDMI 时使用已签名的 Virtual Display Driver 提供 1920×1080 画面。`DJF-Windows-Console-Display` 后台任务依据显示器的父适配器排除虚拟与 RDP 显示器：实体显示器接入时停用新增虚拟设备，移除后启用。只管理安装时确认的虚拟设备，不修改显卡驱动、睡眠或全局 PowerShell 策略。

源码与部署：`install.ps1` 安装官方签名 TightVNC；`ConsoleDesktop.ps1` 校验 DJF 主机并连接现有控制台；`install-display.ps1` 部署签名显示驱动；`install-display-agent.ps1` 安装自动显示任务；`install-macos.py` 为已有独立桌面隧道增加画面转发。设备认证配置沿用现有每用户目录。PowerShell 的 RemoteSigned 仅作用于这些子进程。

查看器复用项目已有 noVNC 1.7.0，保留 MPL-2.0 许可。此副本不请求客户端光标编码，由 Windows 在画面中绘制一个光标，避免已路由时 Mac 光标被冻结而远端光标消失。构建 JS：

```sh
esbuild Console/viewer.js --bundle --minify --format=esm --outfile=Console/viewer.bundle.js
```

`DJFInputRouter --console-check` 在隐藏的同一生产查看器中完成认证及真实帧解码，结果位于 App 数据目录的 `console-check.json`。只记录分辨率及非黑像素采样数量，不保存画面、密码或桌面文字。

当前已验证：djf 为实体控制台 Session 2；无物理显示器时虚拟显示正常；实际 1920×1080 帧解码通过；本地输入允许，USB HID 设备健康。USB 实物按键、HDMI 插拔和查看器的实际手感仍需现场确认。
