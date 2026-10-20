import AppKit
import OSLog

/// One representation of the clipboard, as the core exchanges it.
struct ClipboardItem: Sendable {
    static let text = "text/plain;charset=utf-8"
    static let html = "text/html;charset=utf-8"
    static let png = "image/png"

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

    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private var timer: Timer?

    init() {
        changeCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // What is on the pasteboard already counts as this Mac's clipboard.
        report()
    }

    /// Writes a peer's clipboard. The change this makes is not reported back.
    func write(_ items: [ClipboardItem]) {
        pasteboard.clearContents()
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
        changeCount = pasteboard.changeCount
        Self.log.info("wrote peer clipboard: \(items.map(\.mime), privacy: .public)")
    }

    private func poll() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        report()
    }

    private func report() {
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
        // Files copied in Finder come with their icon as an image: only
        // their names (the text) are shared until files themselves can be.
        if !types.contains(.fileURL), let png = imagePNG() {
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
