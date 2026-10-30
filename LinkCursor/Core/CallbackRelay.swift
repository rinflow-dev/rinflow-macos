import Foundation

/// Owns queued callbacks without retaining their receiver. Invalidating the
/// relay drops work from a stopped core, even if another core has since started.
/// A serial dispatch queue preserves input/reset/control-event ordering.
final class CallbackRelay<Receiver: AnyObject>: Sendable {
    @MainActor private weak var receiver: Receiver?

    @MainActor init(_ receiver: Receiver) {
        self.receiver = receiver
    }

    @MainActor func invalidate() {
        receiver = nil
    }

    func enqueue(_ body: @escaping @MainActor @Sendable (Receiver) -> Void) {
        DispatchQueue.main.async { [self] in
            guard let receiver else { return }
            body(receiver)
        }
    }
}
