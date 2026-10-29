import SwiftUI

/// The Settings window (⌘,). Every change applies at once, except the
/// language, which needs a restart.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
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
                if model.settings.switchHotkeys, model.switchHotkeysBlocked {
                    Label("这组快捷键已被其他程序占用，请换一种组合键。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("指针") {
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
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setting<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: path] },
            set: { value in model.updateSettings { $0[keyPath: path] = value } }
        )
    }
}
