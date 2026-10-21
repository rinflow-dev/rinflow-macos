import AppKit

/// Asks the user to confirm a pairing code (`pairing_requested`). Both
/// devices show the same six digits; the user compares them. The prompt goes
/// away by itself when the core ends the pairing (`pairing_ended`).
@MainActor
final class PairingPrompt {
    private var peerID: String?

    /// Shows the code and reports the answer; nothing when the prompt was
    /// dismissed because the pairing ended elsewhere.
    func ask(peerID: String, name: String, code: String, answer: (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "与 \(name) 配对"
        alert.informativeText = """
        请确认两台设备上显示的数字相同：

        \(Self.grouped(code))

        数字一致时点“配对”，并在对方设备上也确认。
        """
        alert.addButton(withTitle: "配对")
        alert.addButton(withTitle: "取消")
        self.peerID = peerID
        NSApp.activate()
        let response = alert.runModal()
        self.peerID = nil
        switch response {
        case .alertFirstButtonReturn: answer(true)
        case .alertSecondButtonReturn: answer(false)
        default: break // Dismissed: the pairing ended without this answer.
        }
    }

    /// Closes the prompt for `peerID` if it is open.
    func dismiss(peerID: String) {
        guard self.peerID == peerID else { return }
        NSApp.abortModal()
    }

    /// "482917" → "482 917", easier to compare.
    private static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
