import AppKit
import QuickLookUI

// Quick Look on explicit request only (§F05). The shared panel reads the file
// asynchronously, so the bridge holds the item's security scope from `show`
// until the panel closes (or the next preview) — never released mid-read (P1).
final class QuickLookBridge: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookBridge()
    private var url: URL?
    private var holding: URL?
    private var closeObserver: NSObjectProtocol?

    func show(url: URL, holding access: URL? = nil) {
        endHolding()
        holding = access
        guard let panel = QLPreviewPanel.shared() else { endHolding(); return }
        self.url = url
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                self?.endHolding()
            }
    }

    private func endHolding() {
        if let o = closeObserver {
            NotificationCenter.default.removeObserver(o)
            closeObserver = nil
        }
        url = nil
        if let h = holding {
            h.stopAccessingSecurityScopedResource()
            holding = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}
