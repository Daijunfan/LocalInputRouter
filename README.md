# 输入路由（macOS） / Input Router for Mac

这是一个**纯 Mac 应用**：用 Mac 键盘和触控板控制 Windows，不需要 Toolbox。Windows 上的 Deskflow 和 `Support/WindowsReceiver/` 只负责接收输入，没有 Windows 版应用或第二套操作界面。点击 Mac 应用按钮、按自定义快捷键，或在触控板上三指连续轻点两次，可以在两台电脑间切换输入；连续按三次 Esc 会立即停止转发并返回 Mac。

## 安装

**Mac：**安装 [Deskflow](https://github.com/deskflow/deskflow) 1.27 和 Xcode Command Line Tools，运行 `python3 build.py`，打开 `build/Input Router.app`。构建脚本只从本机已安装的 Deskflow 复制运行组件；仓库不包含 Deskflow 二进制文件。应用会在当前 Mac 用户的数据目录中生成专用 SSH 密钥和会话令牌。首次使用需按 macOS 提示授予辅助功能和输入监控权限。

**Windows 接收端准备：**安装 [Deskflow for Windows](https://github.com/deskflow/deskflow) 1.27。用将实际接收键盘输入的 **Windows 管理员账户**打开管理员 PowerShell，运行：

```powershell
./Support/WindowsReceiver/setup.ps1 -MacPublicKey 'ssh-ed25519 AAAA...'
```

这里粘贴 Mac 应用“Windows 设备与配对”里的完整 SSH 公钥。脚本编译并安装当前用户的 Windows 接收器，注册登录任务，启动 OpenSSH Server；SSH 防火墙新规则只接受本地子网。脚本最后显示 Windows 用户名、主机名、局域网 IPv4 和 SSH 主机指纹。其他 Mac 用户可以分别运行一次脚本，追加各自公钥；一台 Windows 同时只由一台 Mac 控制。

在 Mac 应用中填写 Windows 的 IPv4、用户名和主机名，保存后扫描 SSH 指纹。与 Windows 显示的 `SHA256:…` **逐字核对**，再点击信任。随后点击“重新连接”或“启用路由”。首次成功连接时，Mac 会通过已验证的 SSH 连接配置 Windows 接收器的会话令牌；令牌不会写进仓库或显示在界面。局域网可用家庭 Wi-Fi、公司内网或同一热点，IP 改变时在应用里更新即可，不需要公网、云账户或中转机。

## 蓝牙

蓝牙使用同一套 SSH 公钥和主机指纹。先在局域网完成首次身份核对，在操作系统中配对两台电脑，然后在 Windows 重新运行设置脚本并指定 Mac 蓝牙地址：

```powershell
./Support/WindowsReceiver/setup.ps1 -MacPublicKey 'ssh-ed25519 AAAA...' -MacBluetoothAddress 'AA:BB:CC:DD:EE:FF'
```

Windows 蓝牙桥只接受这个 Mac 地址，默认 RFCOMM 通道为 28，只转接 Windows 本机 SSH 端口。Mac 应用填写 Windows 的蓝牙地址及相同通道，选择“蓝牙直连”即可；Mac 的 Wi-Fi 可以继续保持连接。蓝牙速度通常低于 Wi-Fi。切换到另一台 Mac 时，需要在 Windows 更新允许的蓝牙地址。

## 使用与接口

- 路由到 Windows 时，Command 对应 Windows 的 Ctrl，Control 对应 Windows 键，Option 对应 Alt。触控板单指指针、双指精细滚动和多指手势沿用原有输入通道。
- 切换快捷键和紧急返回快捷键可在应用内修改；三次 Esc 为固定保底操作。退出应用时自动停止路由并把输入交还 Mac。
- Mac 程序自身提供 CLI：`--status`、`--switch mac`、`--switch windows`、`--transport direct|bluetooth`、`--pointer-gain 1.50`、`--scroll-gain 1.50`、`--stop`、`--reconnect`。`--status` 返回 JSON，方便脚本读取。普通使用直接点击应用即可。
- macOS 豆包语音实时转发需要 Mac 本身已配置豆包；没有豆包时，键盘、鼠标和触控板仍可使用。

## 数据与安全边界

Mac 应用源码在 `Mac/`，构建输出写入 `build/`；Mac 密钥、主机指纹、会话令牌、用户设置和运行记录位于 `~/Library/Application Support/LocalInputRouter/`。Windows 所需的无界面接收端源码在 `Support/WindowsReceiver/`；它们编译到当前用户的 `%LOCALAPPDATA%\Programs\LocalInputRouter\`，运行数据位于 `%LOCALAPPDATA%\LocalInputRouter\`，蓝牙允许地址位于 `%ProgramData%\LocalInputRouter\`。这些运行目录均不属于公开仓库。

输入数据通过已验证指纹和公钥的 SSH 连接传输。Deskflow 与触控板/语音/剪贴板通道分别占用隧道内的本机回环端口 24900、24901、24903、24904；Windows 局域网中只需要 SSH 端口 22。锁屏后只要 Windows 保持登录和运行即可继续连接；休眠或关机期间无法接收。本开源版的自动 RDP 会话切换未进行通用主机验收，主要支持 Windows 的实体桌面会话。

## 构建与状态

macOS 构建使用当前用户 Keychain 中生成的固定本地签名身份，更新时保持身份；签名私钥不在应用包或 Git 仓库中。原生输入安全逻辑（尤其三次 Esc 回退）沿用已有实现。

本次已在 Mac 上编译并打开独立应用，检查源码清单和签名。按用户要求，当前 Windows 主机不在身边，本次未进行 Windows 接收端或蓝牙的实机验收；公开仓库仅包含 Mac 应用源码与必要的接收端支持源码，不提供 Windows 版应用。

Windows OpenSSH Server 的安装与管理员账户公钥要求见 [Microsoft 文档](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)。Deskflow 二进制及许可证由 [Deskflow 项目](https://github.com/deskflow/deskflow)提供；本仓库只发布本项目源码。

Copyright © 2026 Junfan Dai。本项目原创源码采用 GPL-2.0-or-later 许可证；仓库中的 `LICENSE` 包含 GPL 第 2 版全文，使用者也可以选择该许可证的后续版本。
