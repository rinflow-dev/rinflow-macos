import AppKit
import XCTest

final class ClipboardTests: XCTestCase {
    @MainActor func testPrivateClipboardIsNeverReportedAndStopPreventsReads() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("password", forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        let bridge = ClipboardBridge(pasteboard: pasteboard)
        var reports: [[ClipboardItem]] = []
        bridge.didChange = { reports.append($0) }
        bridge.start()
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].isEmpty)
        bridge.stop()
        pasteboard.clearContents()
        pasteboard.setString("local only", forType: .string)
        bridge.reportIfChanged()
        XCTAssertEqual(reports.count, 1)
        bridge.start()
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(String(decoding: reports[1][0].data, as: UTF8.self), "local only")
        bridge.stop()
    }

    @MainActor func testRemoteClipboardDoesNotEchoAndStartingTwiceDoesNotReportTwice() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bridge = ClipboardBridge(pasteboard: pasteboard)
        var reports = 0
        bridge.didChange = { _ in reports += 1 }
        bridge.start()
        bridge.start()
        XCTAssertEqual(reports, 1)
        bridge.write([ClipboardItem(mime: ClipboardItem.text, data: Data("remote".utf8))])
        bridge.reportIfChanged()
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "remote")
        bridge.stop()
    }
}
