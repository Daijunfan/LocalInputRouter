# DJF 输入路由

## 1.9.12 明确路由边界与 RDP 语音

双轻触拖动、精细滚动、原生多指输入和 Command+X／Command+Backspace 删除只在已确认路由到 Windows 时启用。点击或激活 DJF-Windows 不启用输入路由，未路由时由 Windows App 处理普通输入。Windows 实体 Ctrl+X 保持剪切。

输入目标仍为 Mac、Windows App 的前台窗口标题为 `DJF-Windows`、原有语音接收通道就绪时，仅主动按下 Fn／右 Option 才准备临时 IME 客户端，然后放行真实触发键，不延迟补发。Fn+功能键、Option 组合键保留原路径；1.9.14 的临时客户端选择现有豆包输入法并在结束时恢复原输入法。识别与末尾纠错完成后关闭；切换窗口、返回 Mac 或断开连接时释放它。返回 Mac 先确认释放输入，关闭客户端时不重新抢焦点。Windows 接收端、身份验证与端口沿用现有实现。

检查覆盖原始触发键、Fn+功能键、Option 组合键、未路由 RDP 的普通输入边界、临时输入框收尾、原有拖动与四指切换。真实录音结果单独记录，不将模拟文字检查作为语音验收。

## 1.9.10 原生 RDP 指针与语音焦点

Windows App 的 `DJF-Windows` 窗口使用原生 RDP 指针与点击；键盘和多指手势沿用各自现有通道。触控接收端保持 1.1.0，不再额外绘制光标。非 RDP 路由继续隐藏 Mac 光标并由 Deskflow 发送指针；RDP 指针速度由 Windows App 和系统处理。

双轻触拖动的合成鼠标事件包含点击计数，抬指成对释放。Windows App 的 Full Screen Mode 使用 Immersive，避免移到顶部时显示 Mac 标题和菜单；Fn+F 可退出全屏。

豆包专用输入框支持全屏空间，在空闲且鼠标松开后恢复丢失的焦点。录音已经开始时不重新选择输入源，文字仍通过原有专用通道发送；状态包含 `lastVoiceError`，便于区分识别和 Windows 接收失败。焦点和文字通道检查通过；2026-10-18 用户实际录音确认文字已输入 Windows。

无 HDMI 的共享实体桌面已加入 1.10.0：点击「连接共享实体桌面」，Mac 与机箱 USB 键盘使用同一控制台。查看器内置自动认证，启动和后台检查均不打开窗口；传统 RDP 模式保留。无 HDMI 画面解码已验证，真实按键和显示器插拔单独验收，见 [Console](../Console/README.md)。

已安装的应用：`/Applications/DJF 输入路由.app`。Mac 桌面有同名入口，Windows 已有接收服务，不需要额外执行 PowerShell 命令。

已安装版本使用固定本地签名身份，当前辅助功能权限已验证。更新保留该身份；无需重新添加输入监控权限。

| 操作 | 快捷键 |
|---|---|
| 切换 Mac / DJF-Windows | Control + Option + J（当前用户配置） |
| 紧急返回 Mac并停止后端 | Control + Option + Esc |
| 快速紧急回退 | 1.5 秒内连续按三次 Esc（每次松开） |

三次 Esc 是固定保底回退，不受自定义快捷键影响。第三次按下立即停止后端并恢复 Mac 输入；长按 Esc 不会触发，间隔过长或中间按其他键会重新计数。单次 Esc 保留正常用途。

两种快捷键旁都有「更改」按钮。可以自行组合 Control、Option、Shift、Command，并选择字母、数字、空格或 F 功能键；保存后立即生效并在重启后保留。切换键与紧急返回键不能相同。

触控板切换手势可在「三指轻点两次」（默认）和「四指轻点一次」间选择，保存后立即生效并在重启后保留；未选中的轻点手势继续供 Mac 或 Windows 正常使用。

Apple 键盘上带媒体图标的 F 键默认可能控制播放或亮度。若使用 F8 组合，需要同时按 Fn（🌐）来发送标准 F8；自定义字母或空格不受这一问题影响。见 [Apple 的功能键说明](https://support.apple.com/en-la/102439)。

1.1.0 修复了更新时临时签名身份改变的问题，使用固定的本地证书身份签名。签名私钥保留在应用专用的加密 Keychain，未加入应用或仓库，也未修改系统证书信任。已验证构建内容和哈希改变后，指定的代码身份仍完全相同。

切换按钮只有在后端返回切换确认后才显示目标电脑「正在控制」；两秒内未确认则停止转发并返回 Mac。连接成功与输入实际接管分开显示。

支持键盘、指针移动、点击及滚动。Windows 模式下，Command 对应 Windows Ctrl，Control 对应 Windows 键，Option 对应 Alt。关闭控制窗口后软件仍在菜单栏运行；退出软件则停止转发并交还 Mac 输入。

切换快捷键由 HID 事件钩子优先消费；Deskflow 转发键盘、指针和滚动；最后一道事件钩子丢弃 Windows 模式下遗留的本地事件。紧急返回直接终止转发进程，不等待 Windows 或网络。父进程监视器在软件崩溃时终止后端与隧道。macOS 安全输入开启时暂停路由。多指接触通过独立通道交给 Windows 原生触控板；macOS 专属动作只在目标平台支持时具有对应操作。

通信仅通过已配置的 SSH 密钥、校验过的主机指纹和本地回环端口。局域网模式先直连 `djf.local`，因此校园 Wi-Fi、手机热点等同一内网均可使用；名称不可达时可在界面填备用 IPv4，再查询 bupt208 登记的实体主机地址。登记记录仍要求 DJF-Windows 和 RTX 5060 Ti，Windows 虚拟机不参与本路由。直连失败时可临时复用 `DJF-Windows` SSH 跳板配置，输入回到 Mac 后定期探测直连。没有使用 Tailscale，也没有开放局域网中的输入服务端口。

应用内含原有签名的 Deskflow 1.27 后端和其许可。SSH 身份密钥未打包进应用。源码与构建脚本位于本目录。

```bash
python3 InputRouter/build.py --install
"/Applications/DJF 输入路由.app/Contents/MacOS/DJFInputRouter" --status
```

构建脚本拒绝替换正在运行的已安装应用。普通使用不需要运行命令。

验证记录：原生 Quartz 钩子优先级、切换键按下/释放拦截、长按防重复、本地键盘/滚动拦截、紧急终止与恢复通过；父进程退出后后端及隧道终止通过；已授权的开发进程中，真实 SSH/Deskflow 连接、快捷键 Mac → DJF-Windows → Mac、鼠标/滚动转发时 Mac 光标不动均通过。正常 LaunchServices 启动后的辅助功能和切换按钮也已验证；硬件手感由用户实际确认。

配置依据：[Deskflow 1.27 源码](https://github.com/deskflow/deskflow/tree/v1.27.0)。控制事件使用 Apple 的 [CGEvent.tapPostEvent](https://developer.apple.com/documentation/coregraphics/cgevent/tappostevent(_:))，将控制信号交给后续事件钩子。

## 当前版本 1.4.1：Mac 滚动节奏与独立倍率

双指滚动改为传输 Mac 已计算的精细滚动量与惯性，不再由 Windows 根据双指位置重算滚动。默认滚动倍率 1.50，主窗口支持 0.10–10.00、两位小数输入，与光标倍率分别保存。Windows 接收端使用高精度滚轮单位并保留小数余量；应用如何渲染滚动仍由其自身决定。双指接触只把相对位置用于原生缩放，避免与精细滚动重复；三、四指手势保持原有原生通道。纯逻辑检查、编译、签名、UI 输入应用和真实连接通过，触控板实际手感等待用户确认。

## 1.4.0：通信方式与拖动释放

主窗口的「通信方式」可以选择「校园网直连」或「蓝牙直连」，自动保存选择。切换方式先把输入交还 Mac，再连接所选通道；不会自动切到其他方式。蓝牙模式不改变 Mac 的校园 Wi-Fi 和上网路径。界面的「往返」为原生触控通道最近 20 次心跳的往返中位数，不是屏幕显示延迟。

- 校园网：优先直接 SSH 到实体 Windows；IP 变化时查询服务器中的地址记录。直连受阻时临时经 SSH 跳板传输，恢复后自动切回直连。

Windows App 中 `DJF-Windows` RDP 窗口继续处理原生鼠标坐标与点击。1.9.9 的统一指针路由和接收端光标绘制已撤回。

1.9.2 修复 RDP/实体桌面交接时残留的切换状态：输入客户端断开、重新连接、或已经到达请求的目标时，均清除等待标记，避免三指双击一直被忽略。已验证客户端断开后返回 Mac、恢复连接及再次双向切换。

Windows 的 `Windows/input-session.ps1` 与安装脚本注册会话事件任务：djf 的 RDP 会话活动时，在该会话启动 Deskflow 客户端；RDP 断开后恢复原有 Deskflow 服务，跟随实体控制台。这样避免键盘、鼠标进入锁屏控制台，而手势进入 RDP 桌面的分裂状态。SSH、文件传输及无睡眠设置不受影响。
- 蓝牙：已配对设备通过 RFCOMM 通道 29 承载同一条 SSH 加密连接。Windows 启动任务 `DJF-Windows-Bluetooth-SSH` 运行 `C:\Program Files\DJF Input Router\BluetoothSSHBridge.exe`，只接受本 Mac 蓝牙地址，并只转接 Windows 本机 OpenSSH 端口。原有 SSH 密钥和主机指纹校验保持启用。两种方式复用相同的键盘、指针、原生手势通道。
- Windows 模式拖动过窗口后，内建触控板接触数归零时立即补发左键释放；后续拖移锁定产生的残留 dragged 事件转为普通移动。仅影响本软件转发的拖动，不修改「轻拖」或 Windows 独立鼠标 EXE。

已验证：1.4.0 编译与稳定签名、界面选项、两种方式的真实 SSH/Deskflow/原生多指通道；增益与拖动状态测试通过。硬件抬指拖动的最后确认由用户实测。当前生产通道约为校园网 6–7 ms、蓝牙 30–35 ms 往返，蓝牙不保证更快。

维护命令：`DJFInputRouter --transport direct` 或 `--transport bluetooth`；普通使用直接点击 App 选项。Windows 蓝牙桥安装脚本在 `TrackpadBridge/install-bluetooth.ps1`。更新前的 1.3.1 应用保存在 `artifacts/input-router-1.3.1-backup.zip`。

## 历史记录：1.2.1 鼠标精细定位与 200 倍上限（已被后续版本取代）

Mac 应用中的「Windows 快移倍率」只影响转发到 Windows 的指针。输入 0.1–200，可使用小数。数值大于 1 时表示快速移动的最高增益：慢移沿用原有精细定位，快移逐渐加速；减速时立即降低增益，不加入光标惯性。Mac 本地指针和右 Option 修饰键保持原样。切回 Mac 后同步清除转发目标，避免残留目标误拦截本地输入。

Windows 桌面「鼠标倍速.exe」现为 v2.2，按用户最新要求独立改为 0.10–10.00 固定倍率、两位小数和 ±0.01 按钮。它不再叠加额外的速度曲线，系统“提高指针精确度”仍开启。远端注入的指针事件由 Mac 端调节，Windows 倍率不重复叠加。关闭窗口后程序仍驻留托盘；退出托盘程序即停止额外调速。

恢复操作后，两边倍率均恢复为 1。Windows v2.2 已启用登录任务并运行，应用按钮与实际运行进程的倍率回读已验证；实体鼠标手感等待用户确认。Mac 软件保持原有版本和设置，本轮没有修改。

独立逻辑检查（不会移动鼠标或接管输入）：

```sh
swiftc -parse-as-library InputRouter/Shortcut.swift InputRouter/InputControl.swift InputRouter/PrecisionChecks.swift -framework Carbon -o artifacts/precision-check
artifacts/precision-check
```

先前的恒定倍率像素结果对应 v1.2.0 / Windows v2.0。新版为精度优先的速度曲线，不能把旧的恒定倍率测试结果用作新版的验收记录。

## 1.2.2 路由接收恢复与倍率边界

Windows 必须运行 `Deskflow` 接收服务（启动类型 Automatic），它与桌面「鼠标倍速.exe」是独立程序。本次失联是先前输入恢复时停止了接收服务，却遗漏重新启动。现已恢复服务，并在实际已安装应用中验证 Mac → DJF-Windows → Mac 的双向切换确认。

Mac 界面现标为「Mac 触控板快移倍率」，只调节从 Mac 发出的指针位移；Windows EXE v2.2 只调直连鼠标，并跳过 Deskflow 注入事件，两边不相乘。Windows 直连鼠标当前保留 4.00 倍，Mac 触控板保留 1 倍。维护 Windows 鼠标 EXE 时不要停止 Deskflow；如果为诊断临时停止接收服务，结束前必须恢复并验证真实连接。

## 1.6.2 键位互换与 Mac 豆包实时文字通道

Windows 接收端的修饰键映射为 Command → Ctrl、Control → Windows 键、Option → Alt。只对 DJF-Windows 生效。接收端实际按键观察器已确认两种互换及 Command+Shift 组合；证据在 `artifacts/input-router-1.4.3-modifier-test.json`。

语音使用 App 自己的专用 NSTextView 承接 Mac 豆包输出，按文本变化实时向 Windows 同步。输入框放在透明、不激活应用的 NSPanel 中；原有 Mac 窗口与内容保持原样，豆包录音提示保留。VoiceTextView 同时接收 `setMarkedText` 临时文字、纠错与 `insertText` 最终提交，避免只在录音结束时发送。每轮使用独立 session，结束清空输入框；不读取其他 Mac 应用或剪贴板。文本通道使用已有身份认证密钥，经 SSH 本机转发端口 24803，与手势通道分别处理。Windows `VoiceReceiver.exe` 只监听回环，运行于 djf 的交互桌面登录任务 `DJF-Windows-Voice-Text`。编辑前检查目标身份；其他键盘/点击输入中断本次修改，输入事件始终原样传递。

Fn 按住说话、右 Option 单按采用 Mac 原有配置。函数键组合与 Right Option 组合保留原用途。标准键盘接 Mac 时，右 Alt 对应右 Option；Fn 没有跨键盘统一映射。

本地语音键保留原生事件类型，标记贯穿自己的 Deskflow 后端，最终本地分发前才清除。LocalCursor 独立管理成对的隐藏与恢复；语音 UI 打开、窗口激活和后台刷新时保持 Windows 模式的 Mac 光标隐藏，返回、断线和紧急停止时恢复。

2026-10-07 已安装 1.6.2，用户确认隐藏输入框和实时语音均成功。一次真实录音捕获 19 次临时文字、20 次总更新；Windows 持续确认新增和纠错，结束后输入框字符数为 0；整个录音期间保持 Windows 路由、Mac 光标隐藏，返回 Mac 后光标恢复。证据：`artifacts/voice-hidden-live-state-20261007.jsonl`。原生 IME 临时文字、纠错、提交和清空测试位于 `VoiceTextChecks.swift`。

## Windows 锁屏与校园网

使用校园网模式，不自动切换蓝牙；直连受阻时可临时经 SSH 跳板。Windows 无睡眠、高性能计划保留，WLAN 的“允许计算机关闭此设备以节约电源”已关闭，变更不重启网卡。sshd 自动启动，并设置故障后自动恢复。系统确认锁屏时，两次新的 SSH 会话成功读写测试文件和启动子进程，间隔约 105 秒；后台输入接收进程持续运行。锁屏后台工作与解锁桌面编辑分别处理，正常锁屏不会被自动解除。

锁屏使用原有静态图片，关闭 Spotlight、推荐提示和锁屏小组件；配置脚本为 `../configure-locked-host.ps1`，修改前备份保存在 Windows `C:\ProgramData\DJF-Windows\before-lock-network-20261007`。该 Windows 版本会重新写入旧的 AutoSelectWidgetsOnLockScreen 值，因此只以持续生效的 LockScreenWidgetsEnabled=0 关闭小组件。临时锁屏测试任务已经删除。
