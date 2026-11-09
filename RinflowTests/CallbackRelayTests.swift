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
