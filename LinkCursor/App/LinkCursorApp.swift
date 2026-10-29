import SwiftUI

@main
struct LinkCursorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("LinkCursor", systemImage: "cursorarrow.rays") {
            MenuBarContent(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}


private struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        if let peer = model.connectionState.connectedPeer {
            Text("已连接：\(peer.name)")
            if model.isControlling {
                Button("释放控制", action: model.stopControlling)
            } else {
                let placement = model.placement(for: peer)
                Text(
                    placement.isEnabled
                        ? String(localized: "自动切换：\(placement.edgeDescription)")
                        : String(localized: "请选择设备位置以启用自动切换")
                )
            }
            Button("断开连接") { model.disconnect(peer) }
        } else {
            Text("未连接")
        }

        Divider()

        SettingsLink {
            Text("设置…")
        }
        .keyboardShortcut(",")

        Button("退出 LinkCursor") {
            NSApplication.shared.terminate(nil)
        }
    }
}
