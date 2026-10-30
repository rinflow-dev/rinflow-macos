import SwiftUI
import ServiceManagement

/// The Settings window (⌘,). Every change applies at once, except the
/// language, which needs a restart.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时启动", isOn: Binding(
                    get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                    set: model.setLaunchAtLogin
                ))
                if model.loginStatus == .requiresApproval {
                    Button("在系统设置中允许登录启动", action: model.openLoginSettings)
                }
                Toggle(isOn: setting(\.sharing)) {
                    Text("共享键盘与鼠标")
                    Text("关闭后暂停双向控制，设备保持连接。剪贴板同步由下方开关单独控制。")
                }
                Toggle(isOn: setting(\.clipboard)) {
                    Text("同步剪贴板与文件")
                    Text("切换设备时同步复制的文字、图片和文件。仅在信任对方设备时开启。")
                }
            }
            Section("配对与连接") {
                Toggle(isOn: setting(\.pairedOnly)) {
                    Text("仅允许已配对的设备")
                    Text("新设备需要两边核对六位配对码后才能连接。")
                }
            }

            Section("键盘") {
                Toggle(isOn: setting(\.shortcutRemap)) {
                    Text("沿用 Mac 的快捷键")
                    Text("Windows 控制这台 Mac 时，Ctrl 当作 ⌘ 使用（Ctrl+C 就是 ⌘C）。")
                }
                Toggle(isOn: setting(\.switchHotkeys)) {
                    Text("用快捷键切换设备")
                    Text("\(model.settings.switchModifiers.symbols) 加方向键，把指针移到那一侧的设备上。")
                }
                Picker("组合键", selection: setting(\.switchModifiers)) {
                    ForEach(SwitchModifiers.allCases) { modifiers in
                        Text(verbatim: "\(modifiers.symbols) + ←↑→↓").tag(modifiers)
                    }
                }
                .disabled(!model.settings.switchHotkeys)
                if model.settings.sharing, model.switchHotkeysBlocked {
                    Label("切换或锁定快捷键已被其他程序占用。请修改组合键或关闭冲突程序。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("指针") {
                Text("按 ⌃⌥L 锁定或解锁当前屏幕；按 ⌃⌥⎋ 始终可以释放控制。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: setting(\.pauseInFullscreen)) {
                    Text("全屏时暂停自动切换")
                    Text("游戏或演示全屏时，指针不会从本机屏幕边缘切出。")
                }
                Picker("边缘切换延迟", selection: setting(\.switchDelay)) {
                    Text("无延迟").tag(0.0)
                    Text("短（150 毫秒）").tag(0.15)
                    Text("中（300 毫秒）").tag(0.3)
                    Text("长（500 毫秒）").tag(0.5)
                }
                Toggle(isOn: setting(\.cornerGuard)) {
                    Text("保护屏幕角落")
                    Text("靠近屏幕角落时不自动切换，方便使用菜单和触发角。")
                }
                Toggle(isOn: setting(\.hideCursorOnLeave)) {
                    Text("其他设备的指针离开后隐藏光标")
                    Text("光标只显示在指针所在的设备上；动一下这台 Mac 的鼠标或触控板就会出现。")
                }
            }

            Section("锁屏与唤醒") {
                Toggle(isOn: setting(\.keepAwake)) {
                    Text("其他设备在使用时保持唤醒")
                    Text("在另一台设备上工作时，这台 Mac 不会因闲置而熄屏或锁定。")
                }
                Toggle(isOn: setting(\.lockSync)) {
                    Text("一起锁定")
                    Text("锁定这台 Mac 时其他设备一起锁定，其他设备锁定时这台 Mac 也锁定。")
                }
            }

            Section("语言") {
                Picker("语言", selection: setting(\.language)) {
                    Text("跟随系统").tag(AppLanguage.system)
                    Text(verbatim: "简体中文").tag(AppLanguage.chinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                Text("重新打开 LinkCursor 后生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .onAppear(perform: model.refreshPermission)
    }

    private func setting<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: path] },
            set: { value in model.updateSettings { $0[keyPath: path] = value } }
        )
    }
}
