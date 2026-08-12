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
    }
}

private struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        if let peer = model.connectionState.connectedPeer {
            Text("已连接：\(peer.name)")
            Button(model.isControlling ? "停止控制" : "开始控制") {
                if model.isControlling {
                    model.stopControlling()
                } else {
                    model.startControlling()
                }
            }
            Button("断开连接", action: model.disconnect)
        } else {
            Text("未连接")
        }

        Divider()

        Button("退出 LinkCursor") {
            NSApplication.shared.terminate(nil)
        }
    }
}

