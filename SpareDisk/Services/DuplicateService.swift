import CryptoKit
import Foundation

// Duplicate detection (§F07), run on demand after enumeration — never part
// of the ordinary scan, with its additional read/IO cost stated in the UI.
// Result is "identical file contents", not universal equivalence: metadata,
// resource forks, and application meaning can still differ. Hashes never
// leave the Mac. Cloud placeholders are never hydrated to compare.
nonisolated struct DuplicateGroup: Identifiable, Hashable {
    /// "algorithm:digest" — stable identity for keeper choice.
    let id: String
    var digestHex: String
    var bytesPerFile: Int64
    var files: [ScanNode]
    /// Logical redundancy. Clones may share physical blocks, so Trash may
    /// free less — the UI states this next to the number.
    var redundantLogicalBytes: Int64 { bytesPerFile * Int64(max(0, files.count - 1)) }
}

nonisolated struct DuplicateSkip: Identifiable, Hashable {
    let id: String
    var name: String
    var path: String
    var reason: String
}

nonisolated struct DuplicateProgress: Hashable {
    var checked: Int
    var total: Int
    var current: String
    /// Bytes read so far and the most that could be read, so long
    /// comparisons show movement.
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
}

nonisolated enum DuplicateService {
    static let algorithmVersion = "sha256-v1"
    /// Comparison floor: below this, hashing costs more attention than it saves.
    static let minBytes: Int64 = 1_000_000
    private static let sampleBytes = 64 * 1024
    private static let ioChunk = 1024 * 1024

    /// Compare exactly the files handed in (retained rankings). The caller
    /// holds the grants; files that vanish or change mid-pass leave the
    /// verified set. `onEvent` must be thread-safe (detached worker).
    static func findDuplicates(files: [ScanNode],
                               onEvent: @escaping (DuplicateProgress) -> Void) async -> (groups: [DuplicateGroup], skipped: [DuplicateSkip]) {
        // Reading tens of gigabytes must not starve the interface or other
        // apps: this thread yields the disk to anything with normal priority.
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        defer { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_DEFAULT) }
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
        let sizeGroups = Dictionary(grouping: unique, by: \.logicalBytes).filter { $0.value.count > 1 }
        // Worst case reads every candidate twice: once to hash, once to confirm.
        let bytesTotal = sizeGroups.values.reduce(Int64(0)) { $0 + $1.reduce(0) { $0 + $1.logicalBytes } * 2 }
        var bytesDone: Int64 = 0
        var lastReport = Date.distantPast
        func report(_ name: String, force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) > 0.2 else { return }
            lastReport = now
            onEvent(DuplicateProgress(checked: checked, total: unique.count, current: name,
                                      bytesDone: min(bytesDone, bytesTotal), bytesTotal: bytesTotal))
        }
        for (_, sameSize) in sizeGroups {
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
                    sampleBuckets[try sampleDigest(url: URL(fileURLWithPath: f.path)), default: []].append(f)
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
                        digestBuckets[try shaFile(url: URL(fileURLWithPath: f.path)) { read in
                            bytesDone += read; report(f.name)
                        }, default: []].append(f)
                        checked += 1
                        report(f.name, force: true)
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
                                                 URL(fileURLWithPath: f.path), progress: { read in
                                bytesDone += read; report(f.name)
                            }) {
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
            // Files that dropped out before hashing still count for the estimate.
            let hashed = sampleBuckets.values.filter { $0.count > 1 }.reduce(0) { $0 + $1.count }
            checked += max(0, fresh.count - hashed)
            bytesDone = min(bytesTotal, bytesDone + sameSize.reduce(0) { $0 + $1.logicalBytes } * 2
                            - Int64(hashed) * (sameSize.first?.logicalBytes ?? 0) * 2)
            report(sameSize[0].name, force: true)
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
            guard g.files.allSatisfy({ f in kept.contains { removes($0, f.path) } }) else { continue }
            let keeperID = keepers[g.id] ?? g.files[0].id
            let keeper = g.files.first(where: { $0.id == keeperID }) ?? g.files[0]
            for idx in kept.indices.reversed() where removes(kept[idx], keeper.path) {
                let k = kept.remove(at: idx)
                let direct = CleanupService.standardized(k.node.path) == CleanupService.standardized(keeper.path)
                protected.append(CleanupResult(
                    id: k.id, name: k.node.name, path: k.node.path, bytes: k.node.logicalBytes,
                    outcome: .blocked(direct
                        ? "Kept as the last copy of these contents. Choose a different copy to keep if you want this one removed."
                        : "Contains \(keeper.name), the kept copy of duplicated contents. Choose another copy to keep, or move the copy out first.")))
            }
        }
        return (kept, protected)
    }

    /// Before anything from a group moves, the kept copy must still be a
    /// regular file of the group's size. Otherwise every staged member of
    /// that group is blocked: the queue would otherwise remove the last
    /// intact copy on the strength of a stale comparison.
    static func requireKeepers(plan: [ReviewItem], groups: [DuplicateGroup],
                               keepers: [String: String]) -> (kept: [ReviewItem], blocked: [CleanupResult]) {
        var kept = plan
        var blocked: [CleanupResult] = []
        for g in groups where g.files.count > 1 {
            let keeperID = keepers[g.id] ?? g.files[0].id
            let keeper = g.files.first(where: { $0.id == keeperID }) ?? g.files[0]
            let touched = kept.indices.filter { idx in g.files.contains { removes(kept[idx], $0.path) } }
            guard !touched.isEmpty else { continue }
            let live = ScanEngine.lstat(path: keeper.path)
            let intact = live.map { !$0.isDir && $0.size == g.bytesPerFile } ?? false
            guard !intact else { continue }
            for idx in touched.reversed() {
                let k = kept.remove(at: idx)
                blocked.append(CleanupResult(
                    id: k.id, name: k.node.name, path: k.node.path, bytes: k.node.logicalBytes,
                    outcome: .blocked("The kept copy \(keeper.name) is missing or changed, so nothing from this group was moved. Find duplicates again.")))
            }
        }
        return (kept, blocked)
    }

    /// Whether moving `item` would take the file at `path` with it.
    static func removes(_ item: ReviewItem, _ path: String) -> Bool {
        let p = CleanupService.standardized(item.node.path)
        let q = CleanupService.standardized(path)
        return p == q || (item.node.isFolder && CleanupService.isWithin(q, root: p))
    }

    // MARK: - IO primitives (metadata-only except explicit content reads here)

    private enum Freshness { case ok, changed, gone }

    /// Live facts through the same lstat path the scanner used; timestamps
    /// compare with tolerance (see CleanupService.sameInstant).
    private static func verifyMetadata(_ f: ScanNode) -> Freshness {
        guard let live = ScanEngine.lstat(path: f.path) else { return .gone }
        if live.isDir { return .changed }
        if live.size != f.logicalBytes { return .changed }
        if let old = f.modified, let now = live.modified, !CleanupService.sameInstant(old, now) { return .changed }
        return .ok
    }

    /// A file opened for streaming reads through one reusable buffer. POSIX
    /// reads keep memory flat: FileHandle returned a fresh autoreleased Data
    /// per chunk and a 10 GB file pinned 10 GB until the pool drained.
    /// The file cache is bypassed so a 90 GB comparison does not evict
    /// everything else from memory.
    private final class Reader {
        private let fd: Int32
        let size: Int64
        init(url: URL) throws {
            fd = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            _ = fcntl(fd, F_NOCACHE, 1)
            var st = stat()
            size = fstat(fd, &st) == 0 ? Int64(st.st_size) : 0
        }
        deinit { close(fd) }
        /// Fill `buffer` from the current offset; returns bytes read, 0 at end.
        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            var total = 0
            while total < buffer.count {
                let n = Darwin.read(fd, buffer.baseAddress! + total, buffer.count - total)
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                total += n
            }
            return total
        }
        func seek(to offset: Int64) { lseek(fd, off_t(offset), SEEK_SET) }
    }

    /// Head, middle and tail samples hashed together: rejects almost every
    /// non-duplicate pair for a few hundred kilobytes of reading.
    private static func sampleDigest(url: URL) throws -> String {
        let r = try Reader(url: url)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: sampleBytes, alignment: 16)
        defer { buffer.deallocate() }
        var digest = SHA256()
        let offsets: [Int64] = r.size > Int64(sampleBytes) * 3
            ? [0, r.size / 2 - Int64(sampleBytes) / 2, r.size - Int64(sampleBytes)]
            : [0]
        for off in offsets {
            r.seek(to: off)
            let n = try r.read(into: buffer)
            digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<n]))
        }
        return shaHex(digest.finalize())
    }

    private static func shaFile(url: URL, progress: (Int64) -> Void = { _ in }) throws -> String {
        let r = try Reader(url: url)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: ioChunk, alignment: 16)
        defer { buffer.deallocate() }
        var digest = SHA256()
        while true {
            let n = try r.read(into: buffer)
            if n == 0 { break }
            digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<n]))
            progress(Int64(n))
            if Task.isCancelled { throw CancellationError() }
        }
        return shaHex(digest.finalize())
    }

    private static func contentsEqual(_ a: URL, _ b: URL, progress: (Int64) -> Void = { _ in }) throws -> Bool {
        let ra = try Reader(url: a)
        let rb = try Reader(url: b)
        guard ra.size == rb.size else { return false }
        let ba = UnsafeMutableRawBufferPointer.allocate(byteCount: ioChunk, alignment: 16)
        let bb = UnsafeMutableRawBufferPointer.allocate(byteCount: ioChunk, alignment: 16)
        defer { ba.deallocate(); bb.deallocate() }
        while true {
            let na = try ra.read(into: ba)
            let nb = try rb.read(into: bb)
            if na != nb { return false }
            if na == 0 { return true }
            if memcmp(ba.baseAddress!, bb.baseAddress!, na) != 0 { return false }
            progress(Int64(na))
            if Task.isCancelled { throw CancellationError() }
        }
    }

    private static func shaHex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func skip(_ f: ScanNode, reason: String) -> DuplicateSkip {
        DuplicateSkip(id: f.id, name: f.name, path: f.path, reason: reason)
    }
}
