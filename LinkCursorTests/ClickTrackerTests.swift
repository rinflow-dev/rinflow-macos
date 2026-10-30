import CoreGraphics
import XCTest

final class ClickTrackerTests: XCTestCase {
    func testDoubleAndTripleClicksCarryTheSameCountOnRelease() {
        var clicks = ClickTracker()
        for count in 1...3 {
            let time = Double(count) * 0.15
            XCTAssertEqual(clicks.click(button: 1, down: true, at: .zero, time: time, interval: 0.5), Int64(count))
            XCTAssertEqual(clicks.click(button: 1, down: false, at: .zero, time: time + 0.05, interval: 0.5), Int64(count))
        }
    }

    func testDifferentButtonsDistanceAndTimeoutStartNewClicks() {
        var clicks = ClickTracker()
        XCTAssertEqual(clicks.click(button: 1, down: true, at: .zero, time: 1, interval: 0.5), 1)
        XCTAssertEqual(clicks.click(button: 2, down: true, at: .zero, time: 1.1, interval: 0.5), 1)
        XCTAssertEqual(clicks.click(button: 2, down: true, at: CGPoint(x: 20, y: 0), time: 1.2, interval: 0.5), 1)
        XCTAssertEqual(clicks.click(button: 2, down: true, at: CGPoint(x: 20, y: 0), time: 2, interval: 0.5), 1)
    }
}
