// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import ServiceManagement

/// The Settings window (⌘,). Every change applies at once, except the
/// language, which needs a restart.
struct SettingsView: View {
    let model: AppModel
    /// The page last shown, shown again next time.
    @AppStorage("settings.page") private var page = Page.general

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
                    set: model.setLaunchAtLogin
                ))
                if model.loginStatus == .requiresApproval {
                    Button("在系统设置中允许登录启动", action: model.openLoginSettings)
                }
                Toggle(isOn: setting(\.clipboard)) {
                    Text("同步剪贴板与文件")
                    Text("切换设备时同步复制的文字、图片和文件。仅在信任对方设备时开启。")
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
                }
            } footer: {
                Text("语言在重新打开 LinkCursor 后生效。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keyboard: some View {
        pane {
            Section {
                Toggle(isOn: setting(\.shortcutRemap)) {
                    Text("沿用 Mac 的快捷键")
                    Text("Windows 控制这台 Mac 时，Ctrl 当作 ⌘ 使用（Ctrl+C 就是 ⌘C）。")
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
                    Text("靠近屏幕角落时不自动切换，方便使用菜单和触发角。")
                }
                Toggle(isOn: setting(\.pauseInFullscreen)) {
                    Text("全屏时暂停自动切换")
                    Text("游戏或演示全屏时，指针不会从本机屏幕边缘切出。")
                }
            }
            Section {
                Toggle(isOn: setting(\.hideCursorOnLeave)) {
                    Text("其他设备的指针离开后隐藏光标")
                    Text("光标只显示在指针所在的设备上；动一下这台 Mac 的鼠标或触控板就会出现。")
                }
            }
        }
    }

    private var lock: some View {
        pane {
            Section {
                Toggle(isOn: setting(\.keepAwake)) {
                    Text("其他设备在使用时保持唤醒")
                    Text("在另一台设备上工作时，这台 Mac 不会因闲置而熄屏或锁定。")
                }
                Toggle(isOn: setting(\.lockSync)) {
                    Text("一起锁定")
                    Text("锁定这台 Mac 时其他设备一起锁定，其他设备锁定时这台 Mac 也锁定。")
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
