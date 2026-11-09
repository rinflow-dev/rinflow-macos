// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
        settle { reports.count == 1 }
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].isEmpty)
        bridge.stop()
        pasteboard.clearContents()
        pasteboard.setString("local only", forType: .string)
        bridge.reportIfChanged()
        settle { false }
        XCTAssertEqual(reports.count, 1)
        bridge.start()
        settle { reports.count == 2 }
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
        settle { false }
        XCTAssertEqual(reports, 1)
        bridge.write([ClipboardItem(mime: ClipboardItem.text, data: Data("remote".utf8))])
        bridge.reportIfChanged()
        settle { false }
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "remote")
        bridge.stop()
    }

    @MainActor func testAPeerClipboardWithNothingPasteableKeepsThisMacsCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("mine", forType: .string)
        let bridge = ClipboardBridge(pasteboard: pasteboard)
        bridge.write([ClipboardItem(mime: "text/rtf", data: Data("{\\rtf1}".utf8))])
        XCTAssertEqual(pasteboard.string(forType: .string), "mine")
        bridge.write([ClipboardItem(mime: ClipboardItem.uriList, data: Data("https://example.com/".utf8))])
        XCTAssertEqual(pasteboard.string(forType: .string), "mine")
        bridge.write([
            ClipboardItem(mime: "text/rtf", data: Data("{\\rtf1}".utf8)),
            ClipboardItem(mime: ClipboardItem.text, data: Data("theirs".utf8)),
        ])
        XCTAssertEqual(pasteboard.string(forType: .string), "theirs")
    }

    func testAnOversizedScreenshotIsShrunkInsteadOfDropped() throws {
        // Noise does not compress: like a busy 5K screenshot.
        let side = 1024
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 3, bitsPerPixel: 24
        ))
        var generator = SystemRandomNumberGenerator()
        for index in 0..<(side * side * 3) { rep.bitmapData![index] = UInt8.random(in: 0...255, using: &generator) }
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        XCTAssertEqual(ClipboardBridge.fitting(png, within: png.count), png)
        let shrunk = try XCTUnwrap(ClipboardBridge.fitting(png, within: png.count / 2))
        XCTAssertLessThanOrEqual(shrunk.count, png.count / 2)
        XCTAssertEqual(NSBitmapImageRep(data: shrunk)?.pixelsWide, side / 2)
        XCTAssertNil(ClipboardBridge.fitting(png, within: 100))
    }

    @MainActor func testACopyReplacedWhileConvertingIsNotReported() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old", forType: .string)
        let bridge = ClipboardBridge(pasteboard: pasteboard)
        var reports: [String] = []
        bridge.didChange = { reports.append($0.first.map { String(decoding: $0.data, as: UTF8.self) } ?? "") }
        bridge.start()
        // A peer's clipboard lands before the first report is delivered.
        bridge.write([ClipboardItem(mime: ClipboardItem.text, data: Data("remote".utf8))])
        settle { false }
        XCTAssertEqual(reports, [])
        bridge.stop()
    }

    /// Runs the main run loop (reports come back on it) until `done` or
    /// half a second has passed.
    @MainActor private func settle(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(0.5)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
