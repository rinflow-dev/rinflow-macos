import AppKit
import ImageIO
import OSLog

/// One representation of the clipboard, as the core exchanges it.
struct ClipboardItem: Sendable {
    static let text = "text/plain;charset=utf-8"
    static let html = "text/html;charset=utf-8"
    static let png = "image/png"
    /// Copied files, as `file://` URLs (one per line).
    static let uriList = "text/uri-list"

    let mime: String
    let data: Data
}

/// Reports the system pasteboard to the core and writes peers' clipboards
/// into it. macOS posts no notification when the pasteboard changes, so this
/// polls its change count, as clipboard managers do.
@MainActor
final class ClipboardBridge {
    /// The pasteboard changed; empty when it holds nothing to share.
    var didChange: (([ClipboardItem]) -> Void)?

    /// What the core accepts in all; beyond it the image is left out.
    private nonisolated static let limit = 8 * 1024 * 1024
    /// Marked by password managers and similar apps (nspasteboard.org): never
    /// leaves this Mac.
    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]
    private nonisolated static let log = Logger(subsystem: "com.linkcursor.mac", category: "clipboard")

    private let pasteboard: NSPasteboard
    /// The change count last reported (or written by this bridge).
    private var reportedCount: Int
    private var pendingRead: DispatchWorkItem?
    private var timer: Timer?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        reportedCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // What is on the pasteboard already counts as this Mac's clipboard.
        report()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingRead?.cancel()
        pendingRead = nil
    }

    /// Writes a peer's clipboard. The change this makes is not reported back.
    func write(_ items: [ClipboardItem]) {
        pasteboard.clearContents()
        // Received files: written as files, so Finder pastes them.
        if let list = items.first(where: { $0.mime == ClipboardItem.uriList }) {
            let urls = String(decoding: list.data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { URL(string: String($0)) }
                .filter(\.isFileURL)
            pasteboard.writeObjects(urls as [NSURL])
            reportedCount = pasteboard.changeCount
            Self.log.info("wrote peer files: \(urls.count) items")
            return
        }
        for item in items {
            switch item.mime {
            case ClipboardItem.text:
                if let text = String(data: item.data, encoding: .utf8) {
                    pasteboard.setString(text, forType: .string)
                }
            case ClipboardItem.html:
                pasteboard.setData(item.data, forType: .html)
            case ClipboardItem.png:
                // PNG only: a TIFF of a 5K image is ~60 MB, built on the
                // main thread that also runs the input tap.
                pasteboard.setData(item.data, forType: .png)
            default:
                break
            }
        }
        reportedCount = pasteboard.changeCount
        Self.log.info("wrote peer clipboard: \(items.map(\.mime), privacy: .public)")
    }

    /// Reports a change not reported yet. Called when the pointer leaves for
    /// a peer, so a copy made just before is not left behind by the polling.
    func reportIfChanged() {
        guard timer != nil else { return }
        guard pasteboard.changeCount != reportedCount else { return }
        pendingRead?.cancel()
        pendingRead = nil
        report()
    }

    private func poll() {
        guard pasteboard.changeCount != reportedCount, pendingRead == nil else { return }
        // Writers clear the pasteboard first (that bumps the count) and add
        // their items after: read once they are done, not halfway.
        let read = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingRead = nil
                self?.reportIfChanged()
            }
        }
        pendingRead = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: read)
    }

    /// Copies what the pasteboard holds here; converting an image happens
    /// off the main thread, which also runs the input event tap.
    private func report() {
        let count = pasteboard.changeCount
        reportedCount = count
        let snapshot = snapshot()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = Self.items(from: snapshot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Stopped, or a newer copy (or a peer's clipboard written
                    // here) replaced this one meanwhile.
                    guard let self, self.timer != nil, self.reportedCount == count else { return }
                    Self.log.info(
                        "pasteboard changed: \(items.map { "\($0.mime) \($0.data.count)B" }, privacy: .public)"
                    )
                    self.didChange?(items)
                }
            }
        }
    }

    /// The pasteboard's shareable contents, copied: fast, on the main thread.
    struct Snapshot: Sendable {
        var files: [URL] = []
        var png: Data?
        var tiff: Data?
        var html: Data?
        var text: String?
    }

    private func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        let types = Set(pasteboard.types ?? [])
        guard types.isDisjoint(with: Self.privateTypes) else { return snapshot }
        if types.contains(.fileURL) {
            snapshot.files = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            if !snapshot.files.isEmpty { return snapshot }
        }
        snapshot.png = pasteboard.data(forType: .png)
        if snapshot.png == nil { snapshot.tiff = pasteboard.data(forType: .tiff) }
        snapshot.html = pasteboard.data(forType: .html)
        snapshot.text = pasteboard.string(forType: .string)
        return snapshot
    }

    /// The shareable representations, most specific first.
    nonisolated static func items(from snapshot: Snapshot) -> [ClipboardItem] {
        // Files copied in Finder: the files themselves (the core turns the
        // URLs into a manifest) and their names, never their icon.
        if !snapshot.files.isEmpty {
            let list = snapshot.files.map(\.absoluteString).joined(separator: "\r\n")
            let names = snapshot.files.map(\.lastPathComponent).joined(separator: "\n")
            return [
                ClipboardItem(mime: ClipboardItem.uriList, data: Data(list.utf8)),
                ClipboardItem(mime: ClipboardItem.text, data: Data(names.utf8)),
            ]
        }
        var items: [ClipboardItem] = []
        if let png = imagePNG(snapshot) {
            items.append(ClipboardItem(mime: ClipboardItem.png, data: png))
        }
        if let html = snapshot.html, let utf8 = utf8(html) {
            items.append(ClipboardItem(mime: ClipboardItem.html, data: utf8))
        }
        if let text = snapshot.text {
            items.append(ClipboardItem(mime: ClipboardItem.text, data: Data(text.utf8)))
        }
        // Over the limit, the text still goes: drop the image first.
        while items.count > 1, items.reduce(0, { $0 + $1.data.count }) > limit - 4096 {
            items.removeFirst()
        }
        return items.reduce(0, { $0 + $1.data.count }) > limit - 4096 ? [] : items
    }

    private nonisolated static func imagePNG(_ snapshot: Snapshot) -> Data? {
        let png = snapshot.png ?? snapshot.tiff.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
        guard let png else { return nil }
        let fitted = fitting(png, within: limit - 64 * 1024)
        if fitted?.count != png.count {
            log.info("image \(png.count)B over the limit: \(fitted.map { "shrunk to \($0.count)B" } ?? "left out", privacy: .public)")
        }
        return fitted
    }

    /// A screenshot of a 5K display can be over the core's limit. Halving it
    /// (Retina pixels to points) keeps it readable instead of dropping it.
    nonisolated static func fitting(_ png: Data, within budget: Int) -> Data? {
        guard png.count > budget else { return png }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        var side = max(width, height)
        for _ in 0..<3 {
            side /= 2
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else {
                return nil
            }
            if data.count <= budget { return data }
        }
        return nil
    }

    /// HTML on the pasteboard is UTF-8 or UTF-16; peers get UTF-8.
    private nonisolated static func utf8(_ html: Data) -> Data? {
        if String(data: html, encoding: .utf8) != nil {
            return html
        }
        return String(data: html, encoding: .utf16).map { Data($0.utf8) }
    }
}
