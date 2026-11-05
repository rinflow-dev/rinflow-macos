// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Helpers for scripts/screenshots.sh.
//
//   screenshot-window id <pid>    the number of the process's window, once it is on screen
//   screenshot-window fit <png>   drops the empty rows under the content of a window
//                                 captured with its shadow
//
// The window opens taller than its content needs. Below the content every
// row is the same, edges and shadow included, down to 40 pt above the
// bottom edge, where the rounded corners and their shadow begin. Dropping
// those rows leaves the picture of a window that fits its content.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func windowID(of pid: pid_t) -> Int? {
    for _ in 0..<100 {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        if let window = windows.first(where: {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
        }) {
            return window[kCGWindowNumber as String] as? Int
        }
        usleep(100_000)
    }
    return nil
}

func fit(_ url: URL) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CocoaError(.fileReadCorruptFile) }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space, bitmapInfo: info)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    func row(_ y: Int) -> ArraySlice<UInt8> { pixels[(y * width * 4)..<((y + 1) * width * 4)] }

    // The window's bottom edge: the last opaque pixel down the middle.
    let middle = width / 2
    guard let bottom = (0..<height).last(where: { pixels[($0 * width + middle) * 4 + 3] == 255 })
    else { throw CocoaError(.fileReadCorruptFile) }
    let scale = Int((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyDPIHeight]
        as? Double ?? 144) / 72
    let blank = bottom - 40 * scale
    let reference = row(blank)
    var top = blank
    // A few levels of slack: the dark shadow fades slowly down the sides.
    while top > 0, zip(row(top - 1), reference).allSatisfy({ abs(Int($0) - Int($1)) <= 4 }) {
        top -= 1
    }
    let drop = blank - top
    guard drop > 0 else { return }

    pixels.removeSubrange((top * width * 4)..<(blank * width * 4))
    let fitted = pixels.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: width, height: height - drop, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space, bitmapInfo: info)!.makeImage()!
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    let dpi = Double(72 * scale)
    CGImageDestinationAddImage(destination, fitted,
                               [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let arguments = CommandLine.arguments
switch (arguments.count, arguments.count > 1 ? arguments[1] : "") {
case (3, "id"):
    guard let pid = pid_t(arguments[2]), let id = windowID(of: pid) else { exit(1) }
    print(id)
case (3, "fit"):
    try fit(URL(fileURLWithPath: arguments[2]))
default:
    FileHandle.standardError.write(Data("usage: screenshot-window id <pid> | fit <png>\n".utf8))
    exit(2)
}
