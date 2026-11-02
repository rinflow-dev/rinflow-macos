// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import XCTest

final class InputPlayerTests: XCTestCase {
    @MainActor func testQueuedRelativeMovesAccumulateBeforeTheSystemCursorUpdates() {
        var posted: [CGEvent] = []
        let player = InputPlayer(cursorPosition: { CGPoint(x: 100, y: 100) },
                                 now: { DispatchTime(uptimeNanoseconds: 1_000_000_000) }, post: { posted.append($0) })
        var move = LcInputEvent()
        move.kind = UInt32(LC_INPUT_MOUSE_MOVE)
        move.delta_x = 1
        for _ in 0..<10 { player.play(move) }
        let expected: [CGFloat] = (101...110).map { CGFloat($0) }
        XCTAssertEqual(posted.map { $0.location.x }, expected)
        var click = LcInputEvent()
        click.kind = UInt32(LC_INPUT_MOUSE_BUTTON_DOWN)
        click.code = 1
        player.play(click)
        XCTAssertEqual(posted.last?.location.x, 110)
    }

    @MainActor func testReleaseAllReleasesPressedKeysAndButtonsOnce() {
        var posted: [CGEvent] = []
        let player = InputPlayer(post: { posted.append($0) })
        var key = LcInputEvent()
        key.kind = UInt32(LC_INPUT_KEY_DOWN)
        key.code = 0x04
        player.play(key)
        var button = LcInputEvent()
        button.kind = UInt32(LC_INPUT_MOUSE_BUTTON_DOWN)
        button.code = 1
        player.play(button)
        player.releaseAll()
        XCTAssertEqual(posted.map(\.type), [.keyDown, .leftMouseDown, .keyUp, .leftMouseUp])
        player.releaseAll()
        XCTAssertEqual(posted.count, 4)
        XCTAssertTrue(posted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == SyntheticInput.marker })
    }

    @MainActor func testMouseEventsCarryDoubleClickCounts() {
        var counts: [Int64] = []
        let player = InputPlayer(post: { counts.append($0.getIntegerValueField(.mouseEventClickState)) })
        for _ in 0..<2 {
            var input = LcInputEvent()
            input.code = 1
            input.kind = UInt32(LC_INPUT_MOUSE_BUTTON_DOWN)
            player.play(input)
            input.kind = UInt32(LC_INPUT_MOUSE_BUTTON_UP)
            player.play(input)
        }
        XCTAssertEqual(counts, [1, 1, 2, 2])
    }

    @MainActor func testExtraButtonDragKeepsItsButtonNumber() {
        var posted: CGEvent?
        let player = InputPlayer(post: { posted = $0 })
        var move = LcInputEvent()
        move.kind = UInt32(LC_INPUT_MOUSE_MOVE)
        move.buttons = 1 << 3
        move.delta_x = 2
        player.play(move)
        XCTAssertEqual(posted?.type, .otherMouseDragged)
        XCTAssertEqual(posted?.getIntegerValueField(.mouseEventButtonNumber), 3)
    }

    @MainActor func testScrollRemaindersDoNotMixLineAndPixelUnits() {
        var posted: [CGEvent] = []
        let player = InputPlayer(post: { posted.append($0) })
        var scroll = LcInputEvent()
        scroll.kind = UInt32(LC_INPUT_SCROLL)
        scroll.scroll_y = 5 // half a line, held for the next wheel notch
        player.play(scroll)
        XCTAssertTrue(posted.isEmpty)
        scroll.flags = UInt32(LC_INPUT_FLAG_PRECISE_SCROLL)
        scroll.scroll_y = 0.5 // half a pixel, must not add the half line
        player.play(scroll)
        XCTAssertTrue(posted.isEmpty)
        player.play(scroll)
        XCTAssertEqual(posted.count, 1)
    }
}
