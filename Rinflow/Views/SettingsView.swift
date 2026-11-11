// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import ServiceManagement

/// The Settings window (⌘,). Every change applies at once, except the
/// language, which needs a restart.
struct SettingsView: View {
    let model: AppModel
    @Bindable var updater: Updater
    /// The page last shown, shown again next time.
    @AppStorage("settings.page") private var page = Page.general
    /// 自定义 chosen while the keys still match a preset, as on Windows:
    /// the per-key choices stay shown until a preset is picked again.
    @State private var customModifiers = false

    private enum ModifierPreset: Hashable {
        case mac, keep, custom
    }

    enum Page: String {
        case general, keyboard, pointer, lock
    }

    var body: some View {
        TabView(selection: $page) {
            general
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(Page.general)
            keyboard
                .tabItem { Label("键盘", systemImage: "keyboard") }
                .tag(Page.keyboard)
            pointer
                .tabItem { Label("指针", systemImage: "cursorarrow.motionlines") }
                .tag(Page.pointer)
            lock
                .tabItem { Label("锁屏", systemImage: "lock") }
                .tag(Page.lock)
        }
        .onAppear(perform: model.refreshPermission)
    }

    private var general: some View {
        pane {
            Section {
                Toggle("登录时启动", isOn: Binding(
                    get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                    // A closure, not the method itself: Xcode 26's compiler
                    // crashes on the method in a Release build.
                    set: { model.setLaunchAtLogin($0) }
                ))
                if model.loginStatus == .requiresApproval {
                    Button("在系统设置中允许登录启动", action: model.openLoginSettings)
                }
                Toggle(isOn: setting(\.clipboard)) {
                    Text("同步剪贴板与文件")
                    Text("文字、图片（最大 8 MB）和文件。超过 512 MB 的文件会先询问。")
                }
            }
            Section("安全") {
                Toggle(isOn: setting(\.pairedOnly)) {
                    Text("仅允许已配对的设备")
                    Text("新设备需要两边核对六位配对码后才能连接。")
                }
            }
            Section {
                Picker("外观", selection: setting(\.theme)) {
                    Text("跟随系统").tag(AppTheme.system)
                    Text("浅色").tag(AppTheme.light)
                    Text("深色").tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)
                Picker("语言", selection: setting(\.language)) {
                    Text("跟随系统").tag(AppLanguage.system)
                    Text(verbatim: "简体中文").tag(AppLanguage.chinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "日本語").tag(AppLanguage.japanese)
                }
            } footer: {
                Text("语言在重新打开 Rinflow 后生效。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("更新") {
                LabeledContent("版本") {
                    Text(verbatim: Updater.version)
                        .textSelection(.enabled)
                }
                if updater.isAvailable {
                    Toggle(isOn: $updater.automaticallyChecks) {
                        Text("自动检查更新")
                        Text("有新版本时提示安装。")
                    }
                    Button("检查更新…", action: updater.checkForUpdates)
                }
            }
        }
    }

    private var keyboard: some View {
        pane {
            Section {
                Picker(selection: modifierPreset) {
                    Text("Mac 习惯（推荐）").tag(ModifierPreset.mac)
                    Text("保持键位").tag(ModifierPreset.keep)
                    Text("自定义").tag(ModifierPreset.custom)
                } label: {
                    Text("PC 控制这台 Mac 时的修饰键")
                    Text(modifierDescription)
                }
                if modifierPreset.wrappedValue == .custom {
                    modifierPicker(Text(verbatim: "Ctrl"), \.control)
                    modifierPicker(Text("Windows 键"), \.windows)
                    modifierPicker(Text(verbatim: "Alt"), \.alt)
                }
            }
            Section {
                Toggle(isOn: setting(\.switchHotkeys)) {
                    Text("用快捷键切换设备")
                    Text("组合键加方向键，把鼠标移到那一侧的设备上。")
                }
                Picker("组合键", selection: setting(\.switchModifiers)) {
                    ForEach(SwitchModifiers.allCases) { modifiers in
                        (Text(verbatim: "\(modifiers.symbols) + ") + Text("方向键")).tag(modifiers)
                    }
                }
                .disabled(!model.settings.switchHotkeys)
                if model.settings.sharing, model.switchHotkeysBlocked {
                    Label("切换或锁定快捷键已被其他程序占用。请修改组合键或关闭冲突程序。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("按 ⌃⌥L 锁定或解锁当前屏幕；按 ⌃⌥⎋ 始终可以释放控制。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modifierPreset: Binding<ModifierPreset> {
        Binding(
            get: {
                let map = model.settings.modifierMap
                if customModifiers || (map != .mac && map != .keep) { return .custom }
                return map == .mac ? .mac : .keep
            },
            set: { preset in
                switch preset {
                case .custom:
                    // The choices start from the keys in use; nothing changes yet.
                    customModifiers = true
                case .mac, .keep:
                    customModifiers = false
                    model.updateSettings { $0.modifierMap = preset == .mac ? .mac : .keep }
                }
            }
        )
    }

    private var modifierDescription: String {
        switch modifierPreset.wrappedValue {
        case .mac: String(localized: "Ctrl+C、Ctrl+V 等按 ⌘ 快捷键执行，Windows 键对应 ⌃。")
        case .keep: String(localized: "按键保持原来的位置：Windows 键对应 ⌘，Ctrl 对应 ⌃。")
        case .custom: String(localized: "为 PC 的每个修饰键选择它在这台 Mac 上对应的按键。")
        }
    }

    /// What one of a PC's modifier keys plays as here.
    private func modifierPicker(_ key: Text, _ path: WritableKeyPath<ModifierMap, ModifierTarget>) -> some View {
        let map: WritableKeyPath<AppSettings, ModifierMap> = \.modifierMap
        return Picker(selection: setting(map.appending(path: path))) {
            ForEach(ModifierTarget.allCases) { target in
                switch target {
                case .command: Text(verbatim: "⌘ Command").tag(target)
                case .control: Text(verbatim: "⌃ Control").tag(target)
                case .option: Text(verbatim: "⌥ Option").tag(target)
                case .shift: Text(verbatim: "⇧ Shift").tag(target)
                case .none: Text("无").tag(target)
                }
            }
        } label: {
            key
        }
    }

    private var pointer: some View {
        pane {
            Section {
                Picker("边缘切换延迟", selection: setting(\.switchDelay)) {
                    Text("无延迟").tag(0.0)
                    Text("短（150 毫秒）").tag(0.15)
                    Text("中（300 毫秒）").tag(0.3)
                    Text("长（500 毫秒）").tag(0.5)
                }
                Toggle(isOn: setting(\.cornerGuard)) {
                    Text("保护屏幕角落")
                    Text("靠近屏幕角落时不切换。")
                }
                Toggle(isOn: setting(\.pauseInFullscreen)) {
                    Text("全屏时暂停自动切换")
                    Text("游戏、视频或演示全屏时不切换。")
                }
            }
            Section {
                Toggle(isOn: setting(\.hideCursorOnLeave)) {
                    Text("其他设备的指针离开后隐藏光标")
                    Text("移动这台 Mac 的鼠标或触控板后重新显示。")
                }
            }
        }
    }

    private var lock: some View {
        pane {
            Section {
                Toggle("其他设备在使用时保持唤醒", isOn: setting(\.keepAwake))
                Toggle(isOn: setting(\.lockSync)) {
                    Text("一起锁定")
                    Text("任一设备锁定时，其他设备一起锁定。两端都需打开。")
                }
            }
        }
    }

    /// One page: a grouped form as tall as its content, so the window fits
    /// each page without scrolling, as standard settings windows do.
    private func pane(@ViewBuilder _ content: () -> some View) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .scrollDisabled(true)
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
