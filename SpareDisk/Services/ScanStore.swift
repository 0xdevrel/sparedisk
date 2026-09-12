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
        guard let data = encode(result) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Rewrite the current result in place, leaving the earlier result
    /// alone: an edit to the same scan, not a new scan to compare against.
    static func overwrite(_ result: ScanResult) {
        guard let url = file(for: result.locationID), let data = encode(result) else { return }
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
        return decode(data)
    }

    /// Dates are stored exactly as Foundation holds them: seconds since
    /// 2001 as a Double. That round-trips every representable Date without
    /// loss and, unlike an integer conversion, cannot trap on a date from
    /// an odd archive or a filesystem in the far future.
    static func encode(_ result: ScanResult) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(date.timeIntervalSinceReferenceDate)
        }
        return try? encoder.encode(result)
    }

    /// Reads the Double form, the earlier whole-nanosecond form, and the
    /// original ISO 8601 strings.
    static func decode(_ data: Data) -> ScanResult? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let whole = try? c.decode(Int64.self) {
                // Nanoseconds since 1970 are far larger than any seconds value.
                return abs(whole) > 100_000_000_000
                    ? Date(timeIntervalSince1970: Double(whole) / 1_000_000_000)
                    : Date(timeIntervalSinceReferenceDate: Double(whole))
            }
            if let seconds = try? c.decode(Double.self) {
                return abs(seconds) > 100_000_000_000
                    ? Date(timeIntervalSince1970: seconds / 1_000_000_000)
                    : Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try c.decode(String.self)
            if let d = ISO8601DateFormatter().date(from: text) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unreadable date \(text)")
        }
        return try? decoder.decode(ScanResult.self, from: data)
    }

    static func remove(locationID: String) {
        if let url = file(for: locationID) { try? FileManager.default.removeItem(at: url) }
        if let prev = previousFile(for: locationID) { try? FileManager.default.removeItem(at: prev) }
    }
}
