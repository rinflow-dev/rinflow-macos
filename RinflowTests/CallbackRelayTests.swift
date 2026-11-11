// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

final class CallbackRelayTests: XCTestCase {
    @MainActor private final class Receiver {
        var values: [Int] = []
    }

    @MainActor func testCallbacksPreserveInputAndResetOrdering() async {
        let receiver = Receiver()
        let relay = CallbackRelay(receiver)
        let delivered = expectation(description: "ordered callbacks")
        for value in 0..<100 {
            relay.enqueue { $0.values.append(value) }
        }
        relay.enqueue { _ in delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(receiver.values, Array(0..<100))
    }

    @MainActor func testPreparedCallbacksKeepTheirOrderWithPlainOnesAndRunOffMain() async {
        let receiver = Receiver()
        let relay = CallbackRelay(receiver)
        let delivered = expectation(description: "ordered callbacks")
        for value in 0..<50 {
            if value.isMultiple(of: 2) {
                relay.enqueue(preparing: { () -> Int? in
                    XCTAssertFalse(Thread.isMainThread)
                    // Slow decoding must not let later callbacks overtake it.
                    if value == 10 { Thread.sleep(forTimeInterval: 0.05) }
                    return value
                }) { $0.values.append($1) }
            } else {
                relay.enqueue { $0.values.append(value) }
            }
        }
        // Undecodable: dropped, the rest still delivered.
        relay.enqueue(preparing: { nil as Int? }) { $0.values.append($1) }
        relay.enqueue { _ in delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(receiver.values, Array(0..<50))
    }

    @MainActor func testStoppingDropsQueuedCallbacksFromOldCore() async {
        let receiver = Receiver()
        let relay = CallbackRelay(receiver)
        relay.enqueue { $0.values.append(1) }
        relay.invalidate()
        let delivered = expectation(description: "new core")
        CallbackRelay(receiver).enqueue {
            $0.values.append(2)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(receiver.values, [2])
    }

    private func move(_ dx: Double, _ dy: Double = 0, buttons: UInt32 = 0) -> LcInputEvent {
        var event = LcInputEvent()
        event.kind = UInt32(LC_INPUT_MOUSE_MOVE)
        event.delta_x = dx
        event.delta_y = dy
        event.buttons = buttons
        return event
    }

    func testRunsOfRelativeMovesBecomeOneMoveAndEverythingElseKeepsItsPlace() {
        var click = LcInputEvent()
        click.kind = UInt32(LC_INPUT_MOUSE_BUTTON_DOWN)
        click.code = 1
        click.buttons = 1
        var placed = move(0)
        placed.flags = UInt32(LC_INPUT_FLAG_ABSOLUTE_POSITION)
        placed.x = 100

        let merged = InputBatches.merged([
            move(1, 2), move(3, -1), move(0.5),
            click,
            // A drag: not merged with the motion before the button went down.
            move(2, buttons: 1), move(2, buttons: 1),
            placed,
            move(7),
        ])
        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(merged[0].delta_x, 4.5)
        XCTAssertEqual(merged[0].delta_y, 1)
        XCTAssertEqual(merged[1].kind, UInt32(LC_INPUT_MOUSE_BUTTON_DOWN))
        XCTAssertEqual(merged[2].delta_x, 4)
        XCTAssertEqual(merged[2].buttons, 1)
        XCTAssertEqual(merged[3].x, 100)
        XCTAssertEqual(merged[4].delta_x, 7)
    }

    func testInputJoinsTheQueuedBatchUntilSomethingElseIsQueued() {
        let inputs = InputBatches()
        // The first event starts a batch, to be queued; the next join it.
        guard let first = inputs.add(move(1)) else { return XCTFail("no batch") }
        XCTAssertNil(inputs.add(move(2)))
        // A core event is queued: input after it starts a new batch.
        inputs.seal()
        guard let second = inputs.add(move(10)) else { return XCTFail("no batch") }
        XCTAssertNil(inputs.add(move(20)))

        XCTAssertEqual(inputs.take(first).map(\.delta_x), [3])
        XCTAssertEqual(inputs.take(second).map(\.delta_x), [30])
        // Delivered: what comes now is a new batch again.
        XCTAssertNotNil(inputs.add(move(5)))
    }

    @MainActor func testQueuedWorkDoesNotRetainDestroyedReceiver() async {
        var receiver: Receiver? = Receiver()
        weak let weakReceiver = receiver
        let relay = CallbackRelay(receiver!)
        relay.enqueue { _ in XCTFail("a destroyed receiver must not be used") }
        receiver = nil
        XCTAssertNil(weakReceiver)
        let drained = expectation(description: "queue drained")
        // After the callback above on both of the relay's queues.
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.05)
            DispatchQueue.main.async { drained.fulfill() }
        }
        await fulfillment(of: [drained], timeout: 2)
    }
}
