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
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}
