import AppKit
import Foundation

// Gate A service (§8, §F01): user-selected grants only. No ambient disk access,
// no FDA request, no guessed cross-app authority. Every failure is typed.
enum LocationAccessError: Error, LocalizedError {
    case cancelled
    case bookmarkFailed
    case staleBookmark
    case unavailable
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Selection cancelled. No location was added."
        case .bookmarkFailed: return "Couldn't keep access to that folder. Choose it again."
        case .staleBookmark: return "That location's access expired. Choose it again or scan another location."
        case .unavailable: return "This folder isn't available to the app. Choose it again or scan another location."
        case .readFailed(let s): return s
        }
    }
}

struct GrantedLocation: Hashable {
    let id: String
    let displayName: String
    var url: URL
    var bookmark: Data
}

enum LocationAccessService {
    private static let storeKey = "SpareDisk.LocationBookmarks.v1"

    // MARK: - Open panel (explicit user choice, the only way in)
    @MainActor
    static func pickFolder() async throws -> GrantedLocation {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder to analyze. Files move only after you review and confirm."
        panel.prompt = "Analyze"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow())
        guard response == .OK, let url = panel.url else {
            throw LocationAccessError.cancelled
        }
        return try persistGrant(for: url)
    }

    // MARK: - Bookmark lifecycle
    static func persistGrant(for url: URL) throws -> GrantedLocation {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            let grant = GrantedLocation(id: url.path, displayName: url.lastPathComponent, url: url, bookmark: data)
            var all = loadBookmarks()
            all[url.path] = data
            UserDefaults.standard.set(all, forKey: storeKey)
            return grant
        } catch {
            throw LocationAccessError.bookmarkFailed
        }
    }

    static func loadBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Data] ?? [:]
    }

    /// Resolve a stored grant. Returns a security-scoped URL the caller must
    /// `stopAccessingSecurityScopedResource()` when the whole async operation finishes.
    static func resolve(id: String) throws -> (URL, Bool) {
        guard let data = loadBookmarks()[id] else { throw LocationAccessError.staleBookmark }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            return (url, stale)
        } catch {
            throw LocationAccessError.unavailable
        }
    }

    static func forget(id: String) {
        var all = loadBookmarks()
        all.removeValue(forKey: id)
        UserDefaults.standard.set(all, forKey: storeKey)
    }

    /// Rebuild stored bookmark data while access is held. Call only after a
    /// successful resolve + `startAccessingSecurityScopedResource` (P1).
    static func refreshedURL(id: String, url: URL) throws {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            var all = loadBookmarks()
            all[id] = data
            UserDefaults.standard.set(all, forKey: storeKey)
        } catch {
            throw LocationAccessError.bookmarkFailed
        }
    }
}
