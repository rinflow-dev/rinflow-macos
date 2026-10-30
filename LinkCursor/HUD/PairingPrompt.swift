import AppKit

/// One nonblocking confirmation at a time. Keeping the main run loop free
/// lets pairing timeouts, disconnects and incoming input continue to arrive.
@MainActor
final class PairingPrompt: NSObject, NSWindowDelegate {
    private struct Request {
        let id: String
        let alert: NSAlert
        let answer: (Bool) -> Void
    }
    private var pending: [Request] = []
    private var active: Request?

    func ask(peerID: String, name: String, code: String, answer: @escaping (Bool) -> Void) {
        show(
            id: "pair-\(peerID)",
            title: String(localized: "与 \(name) 配对"),
            message: String(localized: "请确认两台设备上显示的数字相同：\n\n\(Self.grouped(code))\n\n数字一致时点“配对”，并在对方设备上也确认。"),
            accept: String(localized: "配对"), answer: answer
        )
    }

    func show(id: String, title: String, message: String, accept: String, answer: @escaping (Bool) -> Void) {
        guard active?.id != id, !pending.contains(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: accept)
        alert.addButton(withTitle: String(localized: "取消"))
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(answerPrompt(_:))
        }
        alert.buttons[1].keyEquivalent = "\u{1b}"
        pending.append(Request(id: id, alert: alert, answer: answer))
        showNext()
    }

    func dismiss(peerID: String) { dismiss(id: "pair-\(peerID)") }

    func dismiss(id: String) {
        pending.removeAll { $0.id == id }
        if active?.id == id { finish(answer: nil) }
    }

    func dismissFiles() {
        let cancelled = pending.filter { $0.id.hasPrefix("file-") }
        pending.removeAll { $0.id.hasPrefix("file-") }
        for request in cancelled { request.answer(false) }
        if active?.id.hasPrefix("file-") == true { finish(answer: false) }
    }

    func dismissAll() {
        pending.removeAll()
        finish(answer: nil)
    }

    private func showNext() {
        guard active == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        active = request
        request.alert.layout()
        request.alert.window.delegate = self
        request.alert.window.center()
        request.alert.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func answerPrompt(_ button: NSButton) {
        finish(answer: button.tag == 0)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(answer: false)
        return false
    }

    private func finish(answer: Bool?) {
        guard let request = active else { return }
        active = nil
        request.alert.window.delegate = nil
        request.alert.window.orderOut(nil)
        if let answer { request.answer(answer) }
        showNext()
    }

    private static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
