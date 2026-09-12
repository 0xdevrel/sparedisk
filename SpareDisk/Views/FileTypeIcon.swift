import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File-type artwork. Ordinary files and folders use the system icon for
/// their type, cached per extension. Application bundles show their own
/// icon, loaded once per path off the main thread so long lists stay quick.
struct FileTypeIcon: View {
    let node: ScanNode
    var size: CGFloat = 20
    @State private var bundleIcon: NSImage?

    private static var typeCache: [String: NSImage] = [:]
    private static var bundleCache: [String: NSImage] = [:]
    private static let lock = NSLock()

    private var isAppBundle: Bool { node.isPackage && node.name.hasSuffix(".app") }

    private static func typeIcon(for node: ScanNode) -> NSImage {
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
        if let hit = typeCache[key] { return hit }
        let img = NSWorkspace.shared.icon(for: type)
        typeCache[key] = img
        return img
    }

    private static func cachedBundleIcon(_ path: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return bundleCache[path]
    }

    private static func storeBundleIcon(_ image: NSImage, for path: String) {
        lock.lock(); bundleCache[path] = image; lock.unlock()
    }

    var body: some View {
        Image(nsImage: bundleIcon ?? Self.cachedBundleIcon(node.path) ?? Self.typeIcon(for: node))
            .resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: node.path) {
                guard isAppBundle, Self.cachedBundleIcon(node.path) == nil else { return }
                let path = node.path
                let image = await Task.detached(priority: .utility) { () -> NSImage? in
                    guard FileManager.default.fileExists(atPath: path) else { return nil }
                    let img = NSWorkspace.shared.icon(forFile: path)
                    img.size = NSSize(width: 64, height: 64)
                    return img
                }.value
                if let image {
                    Self.storeBundleIcon(image, for: path)
                    bundleIcon = image
                }
            }
    }
}
