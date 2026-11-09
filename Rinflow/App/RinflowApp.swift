// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

@main
struct RinflowApp: App {
    #if DEBUG
    /// `-RinflowScreenshot light|dark` starts with the screenshots' state.
    @State private var model = UserDefaults.standard.string(forKey: "RinflowScreenshot")
        .flatMap(AppTheme.init(rawValue:)).map { AppModel(screenshot: $0) } ?? AppModel()
    #else
    @State private var model = AppModel()
    #endif
    @State private var updater = Updater()

    var body: some Scene {
        Window("Rinflow", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Rinflow", image: "MenuBarIcon") {
            MenuBarContent(model: model, updater: updater)
        }

        Settings {
            SettingsView(model: model, updater: updater)
        }
    }
}


private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel
    let updater: Updater

    var body: some View {
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApp.activate()
        }

        Toggle("共享键盘与鼠标", isOn: Binding(
            get: { model.settings.sharing },
            set: { enabled in model.updateSettings { $0.sharing = enabled } }
        ))
        Toggle("同步剪贴板与文件", isOn: Binding(
            get: { model.settings.clipboard },
            set: { enabled in model.updateSettings { $0.clipboard = enabled } }
        ))
        Divider()

        Button(model.pointerLocked ? "解锁当前屏幕（⌃⌥L）" : "锁定当前屏幕（⌃⌥L）", action: model.togglePointerLock)

        if let peer = model.connectionState.connectedPeer {
            Text("已连接：\(peer.name)")
            if model.isControlling {
                Button("释放控制", action: model.stopControlling)
            } else if model.settings.sharing {
                let placement = model.placement(for: peer)
                Text(
                    placement.isEnabled
                        ? String(localized: "自动切换：\(placement.edgeDescription)")
                        : String(localized: "请选择设备位置以启用自动切换")
                )
            }
        } else {
            Text("未连接")
        }

        ForEach(model.sessions.values.compactMap(\.peer).sorted { $0.id < $1.id }) { peer in
            Button(String(localized: "断开：\(peer.name)")) { model.disconnect(peer) }
        }

        Divider()

        SettingsLink {
            Text("设置…")
        }
        .keyboardShortcut(",")
        if updater.isAvailable {
            Button("检查更新…", action: updater.checkForUpdates)
        }

        Button("退出 Rinflow") {
            NSApplication.shared.terminate(nil)
        }
    }
}
