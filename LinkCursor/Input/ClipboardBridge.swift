import AppKit
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
    private static let limit = 8 * 1024 * 1024
    /// Marked by password managers and similar apps (nspasteboard.org): never
    /// leaves this Mac.
    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]
    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "clipboard")

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
                pasteboard.setData(item.data, forType: .png)
                // Older apps read only TIFF.
                if let tiff = NSBitmapImageRep(data: item.data)?.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
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

    private func report() {
        reportedCount = pasteboard.changeCount
        let items = read()
        Self.log.info(
            "pasteboard changed: \(items.map { "\($0.mime) \($0.data.count)B" }, privacy: .public)"
        )
        didChange?(items)
    }

    /// The shareable representations, most specific first.
    private func read() -> [ClipboardItem] {
        let types = Set(pasteboard.types ?? [])
        guard types.isDisjoint(with: Self.privateTypes) else { return [] }

        var items: [ClipboardItem] = []
        // Files copied in Finder: the files themselves (the core turns the
        // URLs into a manifest) and their names, never their icon.
        if types.contains(.fileURL) {
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            if !urls.isEmpty {
                let list = urls.map(\.absoluteString).joined(separator: "\r\n")
                items.append(ClipboardItem(mime: ClipboardItem.uriList, data: Data(list.utf8)))
                let names = urls.map(\.lastPathComponent).joined(separator: "\n")
                items.append(ClipboardItem(mime: ClipboardItem.text, data: Data(names.utf8)))
                return items
            }
        }
        if let png = imagePNG() {
            items.append(ClipboardItem(mime: ClipboardItem.png, data: png))
        }
        if let html = pasteboard.data(forType: .html), let utf8 = Self.utf8(html) {
            items.append(ClipboardItem(mime: ClipboardItem.html, data: utf8))
        }
        if let text = pasteboard.string(forType: .string) {
            items.append(ClipboardItem(mime: ClipboardItem.text, data: Data(text.utf8)))
        }
        // Over the limit, the text still goes: drop the image first.
        while items.count > 1, items.reduce(0, { $0 + $1.data.count }) > Self.limit - 4096 {
            items.removeFirst()
        }
        return items.reduce(0, { $0 + $1.data.count }) > Self.limit - 4096 ? [] : items
    }

    private func imagePNG() -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// HTML on the pasteboard is UTF-8 or UTF-16; peers get UTF-8.
    private static func utf8(_ html: Data) -> Data? {
        if String(data: html, encoding: .utf8) != nil {
            return html
        }
        return String(data: html, encoding: .utf16).map { Data($0.utf8) }
    }
}
