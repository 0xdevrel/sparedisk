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

    static func save(_ result: ScanResult) {
        guard !result.wasCancelled, let url = file(for: result.locationID) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(result) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load(locationID: String) -> ScanResult? {
        guard let url = file(for: locationID), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanResult.self, from: data)
    }

    static func remove(locationID: String) {
        guard let url = file(for: locationID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
