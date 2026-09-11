import CryptoKit
import Foundation

// Duplicate detection (§F07), run on demand after enumeration — never part
// of the ordinary scan, with its additional read/IO cost stated in the UI.
// Result is "identical file contents", not universal equivalence: metadata,
// resource forks, and application meaning can still differ. Hashes never
// leave the Mac. Cloud placeholders are never hydrated to compare.
struct DuplicateGroup: Identifiable, Hashable {
    /// "algorithm:digest" — stable identity for keeper choice.
    let id: String
    var digestHex: String
    var bytesPerFile: Int64
    var files: [ScanNode]
    /// Logical redundancy. Clones may share physical blocks, so Trash may
    /// free less — the UI states this next to the number.
    var redundantLogicalBytes: Int64 { bytesPerFile * Int64(max(0, files.count - 1)) }
}

struct DuplicateSkip: Identifiable, Hashable {
    let id: String
    var name: String
    var path: String
    var reason: String
}

struct DuplicateProgress: Hashable {
    var checked: Int
    var total: Int
    var current: String
}

enum DuplicateService {
    static let algorithmVersion = "sha256-v1"
    /// Comparison floor: below this, hashing costs more attention than it saves.
    static let minBytes: Int64 = 1_000_000
    private static let sampleBytes = 64 * 1024
    private static let ioChunk = 256 * 1024

    /// Compare exactly the files handed in (retained rankings). The caller
    /// holds the grants; files that vanish or change mid-pass leave the
    /// verified set. `onEvent` must be thread-safe (detached worker).
    static func findDuplicates(files: [ScanNode],
                               onEvent: @escaping (DuplicateProgress) -> Void) async -> (groups: [DuplicateGroup], skipped: [DuplicateSkip]) {
        var skipped: [DuplicateSkip] = []
        // 1. Eligible: size floor, regular local files only.
        var eligible: [ScanNode] = []
        for f in files {
            if f.isFolder { continue }
            if f.logicalBytes < minBytes { continue }
            if f.isCloudPlaceholder {
                skipped.append(skip(f, reason: "Not downloaded, so it was not compared."))
                continue
            }
            eligible.append(f)
        }
        // 2. Collapse hard links: one inode is one file, never "copies".
        var seenIdentity = Set<String>()
        var unique: [ScanNode] = []
        for f in eligible {
            if let ino = f.fsFileNumber, let vol = f.fsVolumeNumber {
                let key = "\(vol):\(ino)"
                if seenIdentity.contains(key) { continue }
                seenIdentity.insert(key)
            }
            unique.append(f)
        }
        // 3. Group by size; singletons can never duplicate.
        var groups: [DuplicateGroup] = []
        var checked = 0
        for (_, sameSize) in Dictionary(grouping: unique, by: \.logicalBytes) where sameSize.count > 1 {
            if Task.isCancelled { break }
            // 4. Recheck metadata right before reading.
            var fresh: [ScanNode] = []
            for f in sameSize {
                if Task.isCancelled { break }
                switch verifyMetadata(f) {
                case .ok: fresh.append(f)
                case .changed: skipped.append(skip(f, reason: "Changed during the comparison."))
                case .gone: skipped.append(skip(f, reason: "Disappeared during comparison."))
                }
            }
            guard fresh.count > 1 else { continue }
            // 5. Sample pass rejects non-matches; a sample never proves equality.
            var sampleBuckets: [String: [ScanNode]] = [:]
            for f in fresh {
                if Task.isCancelled { break }
                do {
                    let data = try readPrefix(url: URL(fileURLWithPath: f.path), maxBytes: sampleBytes)
                    sampleBuckets[shaHex(SHA256.hash(data: data)), default: []].append(f)
                } catch {
                    skipped.append(skip(f, reason: "Could not be read."))
                }
            }
            for (_, contenders) in sampleBuckets where contenders.count > 1 {
                if Task.isCancelled { break }
                // 6. Full streaming digest.
                var digestBuckets: [String: [ScanNode]] = [:]
                for f in contenders {
                    if Task.isCancelled { break }
                    do {
                        digestBuckets[try shaFile(url: URL(fileURLWithPath: f.path)), default: []].append(f)
                    } catch {
                        skipped.append(skip(f, reason: "Could not be read."))
                    }
                }
                for (digest, hashed) in digestBuckets where hashed.count > 1 {
                    if Task.isCancelled { break }
                    // 7. Byte-confirm before treating the group as verified.
                    let anchor = hashed[0]
                    var verified = [anchor]
                    for f in hashed.dropFirst() {
                        if Task.isCancelled { break }
                        do {
                            if try contentsEqual(URL(fileURLWithPath: anchor.path),
                                                 URL(fileURLWithPath: f.path)) {
                                verified.append(f)
                            }
                        } catch {
                            skipped.append(skip(f, reason: "Could not be confirmed."))
                        }
                    }
                    // 8. Final recheck: changed files leave the verified group.
                    verified = verified.filter { verifyMetadata($0) == .ok }
                    guard verified.count > 1 else { continue }
                    let sorted = verified.sorted { $0.path < $1.path }
                    groups.append(DuplicateGroup(id: "\(algorithmVersion):\(digest)",
                                                 digestHex: digest,
                                                 bytesPerFile: anchor.logicalBytes,
                                                 files: sorted))
                }
            }
            checked += fresh.count
            onEvent(DuplicateProgress(checked: checked, total: unique.count, current: sameSize[0].name))
        }
        groups.sort { $0.redundantLogicalBytes > $1.redundantLogicalBytes }
        return (groups, skipped)
    }

    /// Never stage a group's last remaining copy: when the plan holds every
    /// copy, the keeper stays out and is reported. Pure function, unit-tested.
    static func protectKeepers(plan: [ReviewItem], groups: [DuplicateGroup],
                               keepers: [String: String]) -> (kept: [ReviewItem], protected: [CleanupResult]) {
        var kept = plan
        var protected: [CleanupResult] = []
        for g in groups where g.files.count > 1 {
            let memberIDs = Set(g.files.map(\.id))
            guard kept.filter({ memberIDs.contains($0.id) }).count == g.files.count else { continue }
            let keeper = keepers[g.id] ?? g.files[0].id
            if let idx = kept.firstIndex(where: { $0.id == keeper }) {
                let k = kept.remove(at: idx)
                protected.append(CleanupResult(
                    id: k.id, name: k.node.name, path: k.node.path, bytes: k.node.logicalBytes,
                    outcome: .blocked("Kept as the last copy of these contents. Choose a different copy to keep if you want this one removed.")))
            }
        }
        return (kept, protected)
    }

    // MARK: - IO primitives (metadata-only except explicit content reads here)

    private enum Freshness { case ok, changed, gone }

    private static func verifyMetadata(_ f: ScanNode) -> Freshness {
        let url = URL(fileURLWithPath: f.path)
        guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else {
            return .gone
        }
        if vals.isDirectory == true { return .changed }
        if Int64(vals.fileSize ?? -1) != f.logicalBytes { return .changed }
        if let old = f.modified, let now = vals.contentModificationDate, old != now { return .changed }
        return .ok
    }

    private static func readPrefix(url: URL, maxBytes: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return try h.read(upToCount: maxBytes) ?? Data()
    }

    private static func shaFile(url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var digest = SHA256()
        while true {
            guard let data = try h.read(upToCount: ioChunk), !data.isEmpty else { break }
            digest.update(data: data)
        }
        guard !Task.isCancelled else { throw CancellationError() }
        return shaHex(digest.finalize())
    }

    private static func contentsEqual(_ a: URL, _ b: URL) throws -> Bool {
        let ha = try FileHandle(forReadingFrom: a)
        defer { try? ha.close() }
        let hb = try FileHandle(forReadingFrom: b)
        defer { try? hb.close() }
        while true {
            let da = try ha.read(upToCount: ioChunk) ?? Data()
            let db = try hb.read(upToCount: ioChunk) ?? Data()
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }

    private static func shaHex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func skip(_ f: ScanNode, reason: String) -> DuplicateSkip {
        DuplicateSkip(id: f.id, name: f.name, path: f.path, reason: reason)
    }
}
