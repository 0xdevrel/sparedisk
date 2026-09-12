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
    private static let orderKey = "SpareDisk.LocationOrder.v1"

    /// Stored ids in the order the user added them. Bookmarks live in a
    /// dictionary, whose iteration order changes between launches.
    static func orderedIDs() -> [String] {
        let known = Set(loadBookmarks().keys)
        var order = (UserDefaults.standard.stringArray(forKey: orderKey) ?? []).filter { known.contains($0) }
        for id in known.subtracting(order).sorted() { order.append(id) }
        return order
    }

    private static func remember(id: String) {
        var order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        if !order.contains(id) { order.append(id) }
        UserDefaults.standard.set(order, forKey: orderKey)
    }

    // MARK: - Open panel (explicit user choice, the only way in)
    @MainActor
    /// One or more folders chosen by the user. `startingAt` opens the panel
    /// inside that folder so the current folder itself is one click away.
    static func pickFolders(startingAt start: URL? = nil, message: String? = nil) async throws -> [GrantedLocation] {
        let panel = NSOpenPanel()
        panel.message = message ?? "Choose folders to analyze. Nothing moves until you review it and confirm."
        panel.prompt = "Analyze"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.showsHiddenFiles = false
        if let start { panel.directoryURL = start }

        let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow())
        guard response == .OK, !panel.urls.isEmpty else {
            throw LocationAccessError.cancelled
        }
        return try panel.urls.map { try persistGrant(for: $0) }
    }

    static func pickFolder() async throws -> GrantedLocation {
        guard let first = try await pickFolders().first else { throw LocationAccessError.cancelled }
        return first
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
            remember(id: url.path)
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
    /// Folders inside the app's own container need no bookmark. Used by the
    /// UI test fixture and the screenshot demo; never persisted.
    private static let transientLock = NSLock()
    nonisolated(unsafe) private static var transientGrants: [String: URL] = [:]

    static func grantTransient(_ url: URL) -> GrantedLocation {
        transientLock.lock(); transientGrants[url.path] = url; transientLock.unlock()
        return GrantedLocation(id: url.path, displayName: url.lastPathComponent, url: url, bookmark: Data())
    }

    /// Starts security-scoped access, or reports success outright for a
    /// transient grant, whose folder the sandbox can already read.
    static func beginAccess(_ url: URL) -> Bool {
        transientLock.lock(); let transient = transientGrants[url.path] != nil; transientLock.unlock()
        return transient || url.startAccessingSecurityScopedResource()
    }

    static func resolve(id: String) throws -> (URL, Bool) {
        transientLock.lock(); let transient = transientGrants[id]; transientLock.unlock()
        if let transient { return (transient, false) }
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
        var order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        order.removeAll { $0 == id }
        UserDefaults.standard.set(order, forKey: orderKey)
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
