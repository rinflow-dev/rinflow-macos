import CoreGraphics
import XCTest

final class CrossingGateTests: XCTestCase {
    private var portal: Portal {
        Portal(peerID: "pc", side: .right, line: 100, from: 0, to: 100,
               offset: Offset(x: 100, y: 0), peerDisplay: .fallback)
    }

    func testAFastFlickThatStopsAtTheEdgeStillCrossesWhenTheDelayIsUp() {
        // The reported bug: the push ended before the delay, no motion
        // followed, and nothing ever crossed.
        var gate = CrossingGate()
        XCTAssertEqual(gate.push(portal, by: 25, at: 0, delay: 0.15), .began)
        XCTAssertEqual(gate.push(portal, by: 25, at: 0.01, delay: 0.15), .none)
        XCTAssertFalse(gate.isDue(at: 0.1, delay: 0.15))
        XCTAssertTrue(gate.isDue(at: 0.16, delay: 0.15))
    }

    func testAContinuousPushCrossesOnTheEventAfterTheDelay() {
        var gate = CrossingGate()
        XCTAssertEqual(gate.push(portal, by: 10, at: 0, delay: 0.15), .began)
        XCTAssertEqual(gate.push(portal, by: 10, at: 0.1, delay: 0.15), .none)
        XCTAssertEqual(gate.push(portal, by: 10, at: 0.16, delay: 0.15), .cross)
    }

    func testTouchingTheEdgeWithoutPushingFarDoesNotCross() {
        // Reaching the Dock overshoots a little and stops.
        var gate = CrossingGate()
        XCTAssertEqual(gate.push(portal, by: 5, at: 0, delay: 0.15), .began)
        XCTAssertFalse(gate.isDue(at: 0.2, delay: 0.15))
        XCTAssertEqual(gate.push(portal, by: 0, at: 0.3, delay: 0.15), .none)
    }

    func testPausingRestartsAShortPushAndLeavingDropsIt() {
        var gate = CrossingGate()
        _ = gate.push(portal, by: 20, at: 0, delay: 0.15)
        XCTAssertEqual(gate.push(portal, by: 20, at: 1, delay: 0.15), .began)
        XCTAssertEqual(gate.push(nil, by: 0, at: 1.05, delay: 0.15), .none)
        XCTAssertFalse(gate.isDue(at: 1.3, delay: 0.15))
    }

    func testNoDelayCrossesOnceFarEnough() {
        var gate = CrossingGate()
        XCTAssertEqual(gate.push(portal, by: 10, at: 1, delay: 0), .began)
        XCTAssertEqual(gate.push(portal, by: 25, at: 1.01, delay: 0), .cross)
    }

    func testAfterComingBackThereIsNoResistanceButNoBounceEither() {
        var gate = CrossingGate()
        gate.returned(at: 10)
        // A jitter right after landing does not throw the pointer back out.
        XCTAssertEqual(gate.push(portal, by: 2, at: 10.1, delay: 0.15), .none)
        XCTAssertEqual(gate.push(portal, by: 1, at: 12, delay: 0.15), .cross)
        XCTAssertEqual(gate.push(portal, by: 0, at: 12, delay: 0.15), .none)
        XCTAssertEqual(gate.push(portal, by: 1, at: 31, delay: 0.15), .began)
    }

    func testAnUnrelatedDisplayBeyondThePortalDoesNotCross() {
        XCTAssertTrue(portal.isEntered(at: CGPoint(x: 99, y: 50), delta: CGVector(dx: 1, dy: 0)))
        XCTAssertFalse(portal.isEntered(at: CGPoint(x: 500, y: 50), delta: CGVector(dx: 1, dy: 0)))
        XCTAssertFalse(portal.isEntered(at: CGPoint(x: 99, y: 50), delta: CGVector(dx: -1, dy: 0)))
    }
}
