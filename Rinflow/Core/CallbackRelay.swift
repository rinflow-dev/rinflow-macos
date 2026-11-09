// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Owns queued callbacks without retaining their receiver. Invalidating the
/// relay drops work from a stopped core, even if another core has since started.
///
/// Every callback goes through one serial queue, then the main queue: both
/// keep their order, so input, resets and control events stay in the order
/// the core sent them. The serial queue is where a callback's `prepare`
/// work runs (decoding a clipboard of several MB), off the main thread that
/// also runs the input event tap, and off the core's own thread.
final class CallbackRelay<Receiver: AnyObject>: Sendable {
    @MainActor private weak var receiver: Receiver?
    private let queue = DispatchQueue(label: "com.rinflow.core-callbacks", qos: .userInteractive)

    @MainActor init(_ receiver: Receiver) {
        self.receiver = receiver
    }

    @MainActor func invalidate() {
        receiver = nil
    }

    func enqueue(_ body: @escaping @MainActor @Sendable (Receiver) -> Void) {
        enqueue(preparing: { () }) { receiver, _ in body(receiver) }
    }

    /// `prepare` runs off the main thread; nil drops the callback.
    func enqueue<Value: Sendable>(
        preparing prepare: @escaping @Sendable () -> Value?,
        _ body: @escaping @MainActor @Sendable (Receiver, Value) -> Void
    ) {
        queue.async { [self] in
            guard let value = prepare() else { return }
            DispatchQueue.main.async { [self] in
                guard let receiver else { return }
                body(receiver, value)
            }
        }
    }
}
