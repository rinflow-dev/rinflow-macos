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
    /// Input on its way to the main thread (see `InputBatches`).
    let inputs = InputBatches()
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

/// Input from the core, gathered while the main thread is busy.
///
/// Every event used to be its own job for the main thread. When that thread
/// was held up (it also draws the UI), or the network delivered a backlog at
/// once, dozens of moves waited in line and were then played one by one,
/// each a round trip to the window server: the pointer fell further behind
/// just when it had to catch up. Now the events that arrive before the main
/// thread gets to them form one batch, delivered by one job, and a run of
/// relative moves in it is played as a single move.
///
/// Order is kept. A batch is delivered where its first event stood in line.
/// Later events join it only until the core reports anything else (`seal`):
/// input after a core event is played after that event, as before.
final class InputBatches: @unchecked Sendable {
    /// Events delivered together. Its contents belong to `InputBatches`.
    final class Batch: @unchecked Sendable {
        fileprivate var events: [LcInputEvent] = []
    }

    private let lock = NSLock()
    /// The batch that still takes events: queued, not yet delivered.
    private var current: Batch?

    /// Adds an event. Returns the batch to queue for delivery if the event
    /// started one, nil if it joined a batch already queued.
    func add(_ event: LcInputEvent) -> Batch? {
        lock.lock()
        defer { lock.unlock() }
        if let current {
            current.events.append(event)
            return nil
        }
        let batch = Batch()
        batch.events.append(event)
        current = batch
        return batch
    }

    /// Something other than input is being queued: input from here on starts
    /// a new batch, behind it.
    func seal() {
        lock.lock()
        current = nil
        lock.unlock()
    }

    /// Closes `batch` and returns what to play, in order.
    func take(_ batch: Batch) -> [LcInputEvent] {
        lock.lock()
        defer { lock.unlock() }
        if current === batch {
            current = nil
        }
        let events = batch.events
        batch.events = []
        return Self.merged(events)
    }

    /// `events` with every run of relative moves made one move. Keys,
    /// buttons and scrolling keep their place, and so does the absolute move
    /// that places the pointer.
    static func merged(_ events: [LcInputEvent]) -> [LcInputEvent] {
        var result: [LcInputEvent] = []
        result.reserveCapacity(events.count)
        for event in events {
            if let last = result.last,
               isRelativeMove(last), isRelativeMove(event),
               last.buttons == event.buttons, last.modifiers == event.modifiers {
                var joined = event
                joined.delta_x += last.delta_x
                joined.delta_y += last.delta_y
                result[result.count - 1] = joined
            } else {
                result.append(event)
            }
        }
        return result
    }

    private static func isRelativeMove(_ event: LcInputEvent) -> Bool {
        event.kind == UInt32(LC_INPUT_MOUSE_MOVE)
            && event.flags & UInt32(LC_INPUT_FLAG_ABSOLUTE_POSITION) == 0
    }
}
