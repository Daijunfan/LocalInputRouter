import SwiftUI
import AppKit

struct InputRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var router = RouterController()

    var body: some Scene {
        WindowGroup("输入路由") {
            RouterView(router: router)
                .onAppear { delegate.router = router }
        }
        .defaultSize(width: 600, height: 460)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        MenuBarExtra {
            Text(router.destination == .windows ? "正在控制 \(router.peerHost)" : "键盘与触控板在 Mac")
            Divider()
            Button("控制 Mac") { router.select(.mac) }
            Button("控制 Windows") { router.select(.windows) }
            Button("紧急返回 Mac") { router.emergency() }
            Divider()
            Button("重新连接") { router.reconnect() }
            Button("显示控制窗口") { delegate.showWindow() }
            Button("退出输入路由") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: router.destination == .windows ? "desktopcomputer" : "laptopcomputer")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var router: RouterController?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { router?.shutdown() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "输入路由" }?.makeKeyAndOrderFront(nil)
    }
}

struct RouterView: View {
    @ObservedObject var router: RouterController
    @State private var shortcutEdit: ShortcutKind?
    @State private var gainText = "1"
    @State private var gainError = ""
    @State private var scrollText = "1.50"
    @State private var scrollError = ""
    @State private var showGestures = false
    @State private var peerAddress = ""
    @State private var peerUser = ""
    @State private var peerHost = ""
    @State private var bluetoothAddress = ""
    @State private var bluetoothChannel = "28"
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "computermouse.fill")
                    .font(.system(size: 25)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text("一套键盘与触控板，两台电脑").font(.title2.bold())
                    Text(router.switchGesture.title + "，或按切换键，交给另一台电脑").foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                computer(.mac, title: "本机 Mac", detail: "Mac 键盘 · 内建触控板", symbol: "laptopcomputer")
                Image(systemName: "arrow.left.arrow.right").font(.title3).foregroundStyle(.secondary)
                computer(.windows, title: router.peerHost.isEmpty ? "Windows" : router.peerHost,
                         detail: "键盘、鼠标与触控板", symbol: "desktopcomputer")
            }
            HStack(spacing: 8) {
                Circle().fill(router.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(router.status).font(.callout)
                Spacer()
                Text(router.connectionRoute).font(.caption).foregroundStyle(.secondary)
                if !router.address.isEmpty { Text(router.address).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Picker("通信方式", selection: Binding(get: { router.transport }, set: { router.setTransport($0) })) {
                    ForEach(RouterTransport.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).accessibilityLabel("通信方式")
                Text(router.transport.detail + " 切换时输入先返回 Mac。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Windows 设备与配对") {
                VStack(alignment:.leading,spacing:10) {
                    HStack {
                        TextField("局域网 IP",text:$peerAddress).textFieldStyle(.roundedBorder)
                        TextField("登录用户名",text:$peerUser).textFieldStyle(.roundedBorder)
                        TextField("Windows 主机名",text:$peerHost).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        TextField("Windows 蓝牙地址",text:$bluetoothAddress).textFieldStyle(.roundedBorder)
                        TextField("蓝牙通道",text:$bluetoothChannel).textFieldStyle(.roundedBorder).frame(width:85)
                    }
                    HStack {
                        Button("保存设备") {
                            _ = router.configurePeer(address:peerAddress,user:peerUser,host:peerHost,
                                bluetooth:bluetoothAddress,channel:Int(bluetoothChannel) ?? 28)
                        }
                        Button("扫描 SSH 指纹") { router.scanHostFingerprint() }
                            .disabled(router.peerAddress.isEmpty)
                        if !router.hostFingerprint.isEmpty {
                            Text(router.hostFingerprint).font(.caption.monospaced()).textSelection(.enabled)
                            Button("已核对，信任") { router.trustScannedHost() }
                        }
                    }
                    HStack {
                        Text("本机 SSH 公钥：").font(.caption)
                        Text(router.publicKey).lineLimit(2).font(.caption.monospaced()).textSelection(.enabled)
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(router.publicKey,forType:.string)
                        }.disabled(router.publicKey.isEmpty)
                    }
                    Text("Windows 安装脚本会显示主机指纹。先逐字核对，再信任；切换到蓝牙后沿用同一身份。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top,8)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Mac 触控板移动倍率").font(.headline)
                    Spacer()
                    Text("已应用 \(router.pointerGain.formatted()) 倍").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("0.10–10.00", text: $gainText).textFieldStyle(.roundedBorder)
                        .frame(width: 92).accessibilityLabel("Mac 触控板移动倍率")
                        .onSubmit { applyGain() }
                    Text("倍")
                    Button("应用") { applyGain() }.buttonStyle(.borderedProminent)
                    Spacer()
                    ForEach([0.5, 1.0, 2.0], id: \.self) { value in
                        Button("\(value.formatted()) 倍") { gainText = String(value); applyGain() }
                    }
                }
                Text(gainError.isEmpty ? "固定倍率，不叠加额外加速；Windows 实体鼠标仍由 Windows 调节。" : gainError)
                    .font(.caption).foregroundStyle(gainError.isEmpty ? Color.secondary : .red)
                Divider()
                HStack {
                    Text("双指滚动倍率").font(.headline)
                    TextField("0.10–10.00", text: $scrollText).textFieldStyle(.roundedBorder)
                        .frame(width: 80).accessibilityLabel("双指滚动倍率").onSubmit { applyScrollGain() }
                    Button("应用") { applyScrollGain() }.accessibilityLabel("应用双指滚动倍率")
                    Spacer()
                    Text(String(format: "已应用 %.2f 倍", router.scrollGain)).font(.caption).foregroundStyle(.secondary)
                }
                Text(scrollError.isEmpty ? "沿用 Mac 的精细滚动与惯性，滚动速度和光标速度独立调节。" : scrollError)
                    .font(.caption).foregroundStyle(scrollError.isEmpty ? Color.secondary : .red)
            }.padding(18).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: "hand.draw").foregroundStyle(router.gesturesReady ? Color.green : .orange)
                    Text(router.gesturesStatus).font(.callout)
                    Spacer()
                    if router.roundTripMs >= 0 { Text(String(format: "往返 %.1f ms", router.roundTripMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Button("手势说明") { showGestures = true }
                }
                Text("滚动沿用 Mac 的速度与惯性；缩放、三指／四指手势由 Windows 原生触控板处理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 14) {
                HStack {
                    Text("触控板切换手势").font(.callout)
                    Spacer()
                    Picker("触控板切换手势", selection: Binding(get: { router.switchGesture }, set: { router.setSwitchGesture($0) })) {
                        ForEach(TouchSwitchGesture.allCases, id: \.self) { gesture in Text(gesture.title).tag(gesture) }
                    }.labelsHidden().frame(width: 180)
                }
                Divider()
                shortcut("切换 Mac / Windows", keys: router.toggleShortcut.title) { shortcutEdit = .toggle }
                Divider()
                shortcut("紧急返回 Mac", keys: router.emergencyShortcut.title) { shortcutEdit = .emergency }
                Divider()
                HStack {
                    Text("快速紧急回退").font(.callout)
                    Spacer()
                    Text("Esc × 3").font(.system(.body, design: .monospaced).weight(.semibold))
                }
                Text("1.5 秒内连续按三次 Esc，直接停止转发并返回 Mac；长按不会触发。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if router.toggleShortcut.isFunctionKey || router.emergencyShortcut.isFunctionKey {
                    Text("Mac 的 F 功能键通常需要同时按 Fn（🌐），否则会触发播放、亮度等功能。")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            if !router.accessibility {
                HStack {
                    Text("macOS 需要辅助功能权限来控制输入").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("检查辅助功能授权") { router.openPermissions() }
                }
            } else {
                Text("Windows 模式拦截本地输入；⌘ 对应 Ctrl，⌃ 对应 Windows 键，⌥ 对应 Alt。关闭窗口后仍可用，退出软件则返回 Mac。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("重新连接") { router.reconnect() }
                Button(router.running ? "暂停路由" : "启用路由") { router.running ? router.stop() : router.reconnect() }
                Spacer()
                Button("紧急返回 Mac") { router.emergency() }.tint(.orange)
            }
            Text(router.voiceStatus + (router.voiceReady ? " · 实时文字通道已连接" : " · 正在连接文字通道"))
                .font(.caption).foregroundStyle(.secondary)
            Label(router.clipboardStatus, systemImage: "doc.on.clipboard")
                .font(.caption).foregroundStyle(router.clipboardReady ? Color.green : .secondary)
        }
        .padding(28).frame(width: 600)
        .onAppear {
            gainText = String(format: "%.2f", router.pointerGain); scrollText = String(format: "%.2f", router.scrollGain)
            peerAddress=router.peerAddress;peerUser=router.peerUser;peerHost=router.peerHost
            bluetoothAddress=router.bluetoothAddress;bluetoothChannel=String(router.bluetoothChannel)
        }
        .sheet(isPresented: $showGestures) {
            VStack(alignment: .leading, spacing: 15) {
                Text("触控板手势").font(.title2.bold())
                Text("单指移动、轻点、双击、拖动；拖动后抬起手指立即释放，不保留拖移锁定；双指轻点右键。")
                Text("双指：纵向／横向精细滚动和惯性沿用 Mac 的滚动节奏，倍率独立调节；开合缩放由 Windows 原生处理。")
                Text("三指／四指：切换应用、任务视图、显示桌面、切换虚拟桌面及轻点操作，依照 Windows 的触控板设置。")
                Text("缩放、旋转和页面手势需要 Windows 应用支持。Force Touch 查词、Launchpad 等 macOS 专属动作没有通用 Windows 对应，不会在本机触发。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("完成") { showGestures = false }.keyboardShortcut(.defaultAction)
            }.padding(26).frame(width: 450)
        }
        .sheet(item: $shortcutEdit) { kind in ShortcutEditor(router: router, kind: kind) }
    }

    private func applyGain() {
        if let value = Double(gainText.trimmingCharacters(in: .whitespaces)), router.setPointerGain(value) {
            gainText = String(format: "%.2f", router.pointerGain); gainError = ""
        } else { gainError = "请输入 0.10–10.00 之间的数字，例如 2.5。" }
    }
    private func applyScrollGain() {
        if let value = Double(scrollText.trimmingCharacters(in: .whitespaces)), router.setScrollGain(value) {
            scrollText = String(format: "%.2f", router.scrollGain); scrollError = ""
        } else { scrollError = "请输入 0.10–10.00 之间的滚动倍率。" }
    }

    private func computer(_ destination: InputDestination, title: String, detail: String, symbol: String) -> some View {
        let selected = router.destination == destination
        return Button { router.select(destination) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 30))
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                }
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(router.pendingDestination == destination ? "正在切换…" : (selected ? "正在控制" : "点击切换"))
                    .font(.caption.weight(.semibold)).foregroundStyle(selected ? .blue : .secondary)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.blue.opacity(0.09) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.blue : .primary.opacity(0.1), lineWidth: selected ? 2 : 1))
        }.buttonStyle(.plain)
    }

    private func shortcut(_ label: String, keys: String, edit: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Text(keys).font(.system(.body, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.12)))
            Button("更改", action: edit).accessibilityLabel("更改" + label + "快捷键")
        }
    }
}

enum ShortcutKind: String, Identifiable {
    case toggle, emergency
    var id: String { rawValue }
    var title: String { self == .toggle ? "切换 Mac / Windows" : "紧急返回 Mac" }
}

struct ShortcutEditor: View {
    @ObservedObject var router: RouterController
    let kind: ShortcutKind
    @Environment(\.dismiss) private var dismiss
    @State private var value: RouterShortcut
    @State private var error = ""
    init(router: RouterController, kind: ShortcutKind) {
        self.router = router; self.kind = kind
        _value = State(initialValue: kind == .toggle ? router.toggleShortcut : router.emergencyShortcut)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("自定义" + kind.title + "快捷键").font(.title2.bold())
            Text("选择修饰键和主键，保存后立即生效并保留到下次启动。").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                modifier("Control ⌃", .maskControl)
                modifier("Option ⌥", .maskAlternate)
                modifier("Shift ⇧", .maskShift)
                modifier("Command ⌘", .maskCommand)
            }
            Picker("主键", selection: $value.keyCode) {
                ForEach(RouterShortcut.keys) { key in Text(key.title).tag(key.code) }
            }.frame(width: 220)
            Text("当前组合：" + value.title).font(.headline)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("恢复默认") { value = kind == .toggle ? .toggle : .emergency; error = "" }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let failure = router.setShortcut(toggle: kind == .toggle, value: value) { error = failure }
                    else { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 550)
    }
    private func modifier(_ title: String, _ flag: CGEventFlags) -> some View {
        Toggle(title, isOn: Binding(get: { value.modifiers & flag.rawValue != 0 }, set: { on in
            if on { value.modifiers |= flag.rawValue } else { value.modifiers &= ~flag.rawValue }
        })).toggleStyle(.checkbox)
    }
}
