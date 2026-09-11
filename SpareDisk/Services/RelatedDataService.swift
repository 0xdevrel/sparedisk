import Foundation

// Application footprint (§F09), the cautious version: related data is
// located by bundle identifier and exact app name under the user's Library,
// listed as evidence with sizes, and never selected automatically. Removal
// goes through the same review queue as everything else.
nonisolated struct RelatedDataCandidate: Hashable {
    var path: String
    var kind: String
    var evidence: String
}

nonisolated enum RelatedDataService {
    /// Bundle identifier from an app bundle's Info.plist. Metadata only.
    static func bundleIdentifier(appPath: String) -> String? {
        info(appPath: appPath)?["CFBundleIdentifier"] as? String
    }

    private static func info(appPath: String) -> [String: Any]? {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Locations that commonly belong to an app, filtered to those that exist.
    /// Name-based matches are reported as weaker evidence than identifier matches.
    static func candidates(appPath: String, home: String) -> [RelatedDataCandidate] {
        let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let lib = home + "/Library"
        var out: [RelatedDataCandidate] = []
        func add(_ path: String, _ kind: String, _ evidence: String) {
            guard ScanEngine.lstat(path: path) != nil, !out.contains(where: { $0.path == path }) else { return }
            out.append(RelatedDataCandidate(path: path, kind: kind, evidence: evidence))
        }
        if let id = bundleIdentifier(appPath: appPath) {
            let byID = "Bundle identifier \(id)"
            add("\(lib)/Containers/\(id)", "Container", byID)
            add("\(lib)/Group Containers/\(id)", "Group container", byID)
            add("\(lib)/Application Support/\(id)", "Application Support", byID)
            add("\(lib)/Caches/\(id)", "Cache", byID)
            add("\(lib)/HTTPStorages/\(id)", "Web storage", byID)
            add("\(lib)/WebKit/\(id)", "WebKit data", byID)
            add("\(lib)/Preferences/\(id).plist", "Preferences", byID)
            add("\(lib)/Saved Application State/\(id).savedState", "Saved state", byID)
            add("\(lib)/Logs/\(id)", "Logs", byID)
            add("\(lib)/Application Scripts/\(id)", "Scripts", byID)
            // Group containers and shared containers often carry a team prefix.
            if let groups = try? FileManager.default.contentsOfDirectory(atPath: "\(lib)/Group Containers") {
                for g in groups where g.hasSuffix(".\(id)") || g.hasSuffix(id) {
                    add("\(lib)/Group Containers/\(g)", "Group container", "Shares identifier \(id)")
                }
            }
        }
        // Names the app calls itself: display name, bundle name, executable
        // ("Code" for Visual Studio Code), and the vendor folder many apps
        // use (Google/Chrome, Mozilla/Firefox).
        var names = [name]
        let plist = info(appPath: appPath)
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            if let v = plist?[key] as? String, !v.isEmpty, !names.contains(v) { names.append(v) }
        }
        for n in names {
            add("\(lib)/Application Support/\(n)", "Application Support", "Same name as the app")
            add("\(lib)/Caches/\(n)", "Cache", "Same name as the app")
            add("\(lib)/Logs/\(n)", "Logs", "Same name as the app")
        }
        if let id = bundleIdentifier(appPath: appPath) {
            let parts = id.split(separator: ".")
            if parts.count >= 3 {
                let vendor = String(parts[1]).capitalized
                let product = String(parts[2])
                for n in [product] + names {
                    add("\(lib)/Application Support/\(vendor)/\(n)", "Application Support", "Vendor folder from \(id)")
                    add("\(lib)/Caches/\(vendor)/\(n)", "Cache", "Vendor folder from \(id)")
                }
            }
        }
        return out
    }
}
