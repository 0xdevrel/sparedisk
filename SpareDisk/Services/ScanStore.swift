import CryptoKit
import Foundation

// Saved scans (§F11, first step): the last completed result per location is
// kept in the app container so a relaunch shows dated results instead of
// "Not scanned yet". A saved scan is metadata only, never file contents, and
// nothing is deleted from a saved path without a fresh revalidation.
nonisolated enum ScanStore {
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("SpareDisk/Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(for locationID: String) -> URL? {
        let digest = SHA256.hash(data: Data(locationID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent("\(digest).json")
    }

    private static func previousFile(for locationID: String) -> URL? {
        file(for: locationID).map { $0.deletingPathExtension().appendingPathExtension("prev.json") }
    }

    static func save(_ result: ScanResult) {
        guard !result.wasCancelled, let url = file(for: result.locationID) else { return }
        // Keep exactly one earlier result for comparison.
        if let prev = previousFile(for: result.locationID), FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.moveItem(at: url, to: prev)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(result) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadPrevious(locationID: String) -> ScanResult? {
        guard let url = previousFile(for: locationID) else { return nil }
        return load(from: url)
    }

    static func load(locationID: String) -> ScanResult? {
        guard let url = file(for: locationID) else { return nil }
        return load(from: url)
    }

    private static func load(from url: URL) -> ScanResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanResult.self, from: data)
    }

    static func remove(locationID: String) {
        if let url = file(for: locationID) { try? FileManager.default.removeItem(at: url) }
        if let prev = previousFile(for: locationID) { try? FileManager.default.removeItem(at: prev) }
    }
}
