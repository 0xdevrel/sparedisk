import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// System file-type artwork without reading file contents. Icons are cached
/// per extension so long lists do not rebuild NSImages on every redraw.
struct FileTypeIcon: View {
    let node: ScanNode
    var size: CGFloat = 20

    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    private static func icon(for node: ScanNode) -> NSImage {
        let key: String
        let type: UTType
        if node.isPackage && node.name.hasSuffix(".app") { key = "#app"; type = .applicationBundle }
        else if node.isFolder { key = node.isPackage ? "#pkg" : "#folder"; type = node.isPackage ? .package : .folder }
        else {
            let ext = (node.name as NSString).pathExtension.lowercased()
            key = ext
            type = UTType(filenameExtension: ext) ?? .data
        }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let img = NSWorkspace.shared.icon(for: type)
        cache[key] = img
        return img
    }

    var body: some View {
        Image(nsImage: Self.icon(for: node))
            .resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
