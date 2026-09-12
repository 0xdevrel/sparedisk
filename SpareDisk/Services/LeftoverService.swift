import Foundation

// Leftovers (§F09, second half): entries under the user's Library that are
// named after a bundle identifier with no application installed for it.
// Pure classification lives here; the app decides what "installed" means.
nonisolated struct LeftoverEntry: Hashable {
    var bundleID: String
    var path: String
    var kind: String
}

nonisolated struct LeftoverGroup: Identifiable, Hashable {
    var id: String { bundleID }
    var bundleID: String
    var items: [ScanNode]
    var bytes: Int64 { items.reduce(0) { $0 + $1.logicalBytes } }
    var newestChange: Date? { items.compactMap(\.modified).max() }
    /// Readable name from the identifier: "com.acme.SuperApp" reads
    /// "SuperApp", and generic tails such as "com.murmur.app" read "Murmur".
    var displayName: String {
        let generic: Set<String> = ["app", "mac", "macos", "osx", "desktop", "client", "helper", "agent", "plist", "main"]
        let parts = bundleID.split(separator: ".").map(String.init)
        var pick = parts.reversed().first { !generic.contains($0.lowercased()) } ?? parts.last ?? bundleID
        if pick.count > 1, pick == pick.lowercased() { pick = pick.prefix(1).uppercased() + pick.dropFirst() }
        return pick
    }
}

nonisolated enum LeftoverService {
    /// Library folders whose entries are named by bundle identifier, and the
    /// suffix each strips before the identifier appears.
    static let places: [(folder: String, kind: String, suffix: String)] = [
        ("Containers", "Container", ""),
        ("Group Containers", "Group container", ""),
        ("Application Support", "Application Support", ""),
        ("Caches", "Cache", ""),
        ("HTTPStorages", "Web storage", ""),
        ("WebKit", "WebKit data", ""),
        ("Preferences", "Preferences", ".plist"),
        ("Saved Application State", "Saved state", ".savedState"),
        ("Logs", "Logs", ""),
        ("Application Scripts", "Scripts", ""),
        ("Cookies", "Cookies", ".binarycookies"),
    ]

    /// The bundle identifier a Library entry name stands for, or nil when the
    /// name is not one. Team prefixes on group containers ("ABCDE12345.com.x")
    /// and the "group." prefix are stripped.
    static func bundleID(fromEntryName raw: String, suffix: String) -> String? {
        var name = raw
        if !suffix.isEmpty {
            guard name.hasSuffix(suffix) else { return nil }
            name.removeLast(suffix.count)
        }
        if name.hasPrefix("group.") { name.removeFirst(6) }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var comps = parts
        if let first = comps.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }), comps.count >= 3 {
            comps.removeFirst()   // team identifier prefix
        }
        // Reverse DNS: a short top-level label, a vendor, and at least one
        // product component. Two-part names such as "default.store" are files.
        guard comps.count >= 3, comps.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }) else { return nil }
        let tld = comps[0].lowercased()
        guard tld.allSatisfy(\.isLetter), tld.count <= 3 || longTopLevelLabels.contains(tld), tld.count >= 2 else { return nil }
        return comps.joined(separator: ".")
    }

    /// Labels longer than three letters that vendors actually use at the
    /// front of a bundle identifier. Anything else that long is a file name.
    static let longTopLevelLabels: Set<String> = [
        "info", "name", "mobi", "cloud", "studio", "design", "software", "systems", "tools", "games",
        "video", "audio", "music", "news", "media", "tech", "team", "works", "codes", "live", "world",
        "space", "store", "site", "shop", "blog", "plus", "digital", "agency", "network", "solutions",
        "engineering", "science", "email", "chat", "social", "photo", "photos", "wiki", "open", "local",
    ]

    /// Apple's own identifiers belong to system components, most of which
    /// have no app bundle; they are never reported.
    static func isSystem(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix("com.apple.")
    }

    /// Identifier prefixes to test for an installed owner: helpers such as
    /// "com.acme.App.Helper" belong to "com.acme.App".
    static func ownerCandidates(_ bundleID: String) -> [String] {
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return [bundleID] }
        return (3...parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }
    }

    /// The user's real home folder. Inside the sandbox NSHomeDirectory()
    /// is the app container, so the account record is asked instead.
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Every entry under the Library folders whose name is a bundle
    /// identifier, excluding Apple's. Metadata only; nothing is read.
    static func entries(home: String) -> [LeftoverEntry] {
        var out: [LeftoverEntry] = []
        for place in places {
            let dir = home + "/Library/" + place.folder
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names {
                guard let id = bundleID(fromEntryName: n, suffix: place.suffix), !isSystem(id) else { continue }
                out.append(LeftoverEntry(bundleID: id, path: dir + "/" + n, kind: place.kind))
            }
        }
        return out
    }

    /// Entries whose identifier, and none of its owning prefixes, has an
    /// installed or running application.
    static func orphans(_ entries: [LeftoverEntry], isInstalled: (String) -> Bool) -> [LeftoverEntry] {
        var verdict: [String: Bool] = [:]
        return entries.filter { e in
            if let v = verdict[e.bundleID] { return !v }
            let installed = ownerCandidates(e.bundleID).contains { isInstalled($0) }
            verdict[e.bundleID] = installed
            return !installed
        }
    }
}

/// What an Uninstall proposes for one app: the bundle plus its related
/// data split by how sure the match is.
nonisolated struct UninstallPlan: Identifiable, Hashable {
    var id: String { app.id }
    var app: ScanNode
    var strong: [ScanNode]
    var weak: [ScanNode]

    /// Identifier matches are reliable; name and vendor-folder matches may
    /// belong to something else and start unchecked.
    static func split(related: [ScanNode], evidence: [String: String]) -> (strong: [ScanNode], weak: [ScanNode]) {
        var strong: [ScanNode] = [], weak: [ScanNode] = []
        for n in related {
            let e = evidence[n.path] ?? ""
            if e.contains("Bundle identifier") || e.contains("Shares identifier") { strong.append(n) } else { weak.append(n) }
        }
        return (strong, weak)
    }
}
