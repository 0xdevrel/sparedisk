import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Uses the system file-type artwork without reading file contents or requesting access.
struct FileTypeIcon: View {
    let node: ScanNode
    var size: CGFloat = 20

    private var type: UTType {
        if node.isFolder { return .folder }
        return UTType(filenameExtension: URL(fileURLWithPath: node.path).pathExtension) ?? .data
    }

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
