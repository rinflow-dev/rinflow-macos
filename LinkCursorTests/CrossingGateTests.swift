import CoreGraphics
import XCTest

final class CrossingGateTests: XCTestCase {
    private var portal: Portal {
        Portal(peerID: "pc", side: .right, line: 100, from: 0, to: 100,
               offset: Offset(x: 100, y: 0), peerDisplay: .fallback)
    }

    func testAContinuousPushWaitsForTheDelay() {
        var gate = CrossingGate()
        XCTAssertFalse(gate.allows(portal, at: 0, delay: 0.15))
        XCTAssertFalse(gate.allows(portal, at: 0.1, delay: 0.15))
        XCTAssertTrue(gate.allows(portal, at: 0.16, delay: 0.15))
    }

    func testRestingOrLeavingTheEdgeRestartsTheDelay() {
        var gate = CrossingGate()
        XCTAssertFalse(gate.allows(portal, at: 0, delay: 0.15))
        XCTAssertFalse(gate.allows(portal, at: 1, delay: 0.15))
        XCTAssertFalse(gate.allows(nil, at: 1.1, delay: 0.15))
        XCTAssertFalse(gate.allows(portal, at: 1.2, delay: 0.15))
        XCTAssertTrue(gate.allows(portal, at: 1.36, delay: 0.15))
    }

    func testNoDelayAllowsImmediateCrossing() {
        var gate = CrossingGate()
        XCTAssertTrue(gate.allows(portal, at: 1, delay: 0))
    }

    func testAnUnrelatedDisplayBeyondThePortalDoesNotCross() {
        XCTAssertTrue(portal.isEntered(at: CGPoint(x: 99, y: 50), delta: CGVector(dx: 1, dy: 0)))
        XCTAssertFalse(portal.isEntered(at: CGPoint(x: 500, y: 50), delta: CGVector(dx: 1, dy: 0)))
        XCTAssertFalse(portal.isEntered(at: CGPoint(x: 99, y: 50), delta: CGVector(dx: -1, dy: 0)))
    }
}
