import CryptoKit
import Foundation
import ImageIO

public struct SyncReport: Sendable {
    public var added: [Track]
    public var skippedDuplicates: [URL]
    public var failed: [(URL, String)]
    public var removed: Int
    public var warnings: [String]

    public init(added: [Track] = [], skippedDuplicates: [URL] = [], failed: [(URL, String)] = [], removed: Int = 0, warnings: [String] = []) {
        self.added = added
        self.skippedDuplicates = skippedDuplicates
        self.failed = failed
        self.removed = removed
        self.warnings = warnings
    }
}

public struct SyncProgress: Sendable {
    public var phase: String
    public var current: Int
    public var total: Int
    public var fraction: Double
    public var item: String?

    public init(phase: String, current: Int, total: Int, fraction: Double, item: String? = nil) {
        self.phase = phase
        self.current = current
        self.total = total
        self.fraction = fraction
        self.item = item
    }
}

public enum FaultPoint: Sendable, Equatable {
    case afterCopyBeforeDB, duringDBWrite, touchDatabaseAfterConversion
    case duringCopy(index: Int)
}

public enum SyncError: Error {
    case notEnoughSpace(needed: Int64, free: Int64)
    case roundTripMismatch
    case guidUnverified
    case databaseChanged
    case ioFailure(String)
}

public actor SyncSession {
    static let supportedExtensions: Set<String> = ["flac", "m4a", "wav", "aif", "aiff", "mp3"]
    static let spaceMargin: Int64 = 50_000_000

    private let device: IPodDevice
    private let backupsRoot: URL
    private let workDir: URL
    private let guidOverride: [UInt8]?
    private let fault: FaultPoint?

    public static var defaultBackupsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Connector/Backups", isDirectory: true)
    }

    public static var defaultWorkDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Connector", isDirectory: true)
    }

    public init(
        device: IPodDevice,
        backupsRoot: URL = SyncSession.defaultBackupsRoot,
        workDir: URL = SyncSession.defaultWorkDir,
        guidOverride: [UInt8]? = nil,
        faultInjection: FaultPoint? = nil
    ) {
        self.device = device
        self.backupsRoot = backupsRoot
        self.workDir = workDir
        self.guidOverride = guidOverride
        self.fault = faultInjection
    }

    private var control: URL { device.controlDir }
    private var dbURL: URL { control.appendingPathComponent("iTunes/iTunesDB") }
    private var playCountsURL: URL { control.appendingPathComponent("iTunes/Play Counts") }
    private var artworkDir: URL { control.appendingPathComponent("Artwork", isDirectory: true) }
    private var artworkDBURL: URL { artworkDir.appendingPathComponent("ArtworkDB") }

    public func load() throws -> [Track] {
        try loadLibrary().tracks
    }

    public func loadLibrary() throws -> (tracks: [Track], deviceName: String?) {
        let data = try readDB()
        guard let db = try? ITunesDB(data: data) else { throw SyncError.roundTripMismatch }
        return (db.tracks, db.deviceName)
    }

    public func add(_ urls: [URL], progress: @Sendable (SyncProgress) -> Void) async throws -> SyncReport {
        let opened = try openForWrite()
        let db = opened.db
        var report = SyncReport()
        let counts = try parsePlayCounts()

        var seen = Set(db.tracks.map { Self.key($0.artist, $0.album, $0.title, $0.trackNumber) })
        var candidates: [MediaInfo] = []
        let files = Self.expand(urls)
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            progress(SyncProgress(phase: "Reading", current: index + 1, total: files.count, fraction: Double(index) / Double(max(1, files.count)), item: url.lastPathComponent))
            let info: MediaInfo
            do { info = try await MediaReader.read(url) } catch {
                report.failed.append((url, "\(error)"))
                continue
            }
            let key = Self.key(info.artist, info.album, info.title, info.trackNumber)
            if seen.contains(key) { report.skippedDuplicates.append(url); continue }
            seen.insert(key)
            candidates.append(info)
        }

        var prepared: [(MediaInfo, PreparedFile)] = []
        func cleanWork() { for (_, file) in prepared { try? FileManager.default.removeItem(at: file.url) } }
        defer { cleanWork() }
        for (index, info) in candidates.enumerated() {
            try Task.checkCancellation()
            progress(SyncProgress(phase: "Converting", current: index + 1, total: candidates.count, fraction: Double(index) / Double(candidates.count), item: info.kind.isLossless ? "\(info.url.lastPathComponent) → ALAC 16/44.1" : "\(info.url.lastPathComponent) (direct copy)"))
            do { prepared.append((info, try await prepare(info))) } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failed.append((info.url, "\(error)"))
            }
        }
        guard !prepared.isEmpty else { return report }

        let needed = prepared.reduce(Int64(0)) { $0 + Int64($1.1.sizeBytes) } + Self.spaceMargin
        guard device.freeBytes >= needed else { throw SyncError.notEnoughSpace(needed: needed, free: device.freeBytes) }
        try Task.checkCancellation()

        if fault == .touchDatabaseAfterConversion {
            var tampered = try readDB()
            tampered.append(0)
            try tampered.write(to: dbURL)
        }
        try ensureUnchanged(opened.original)

        try Backup.perform(controlDir: control, backupsRoot: backupsRoot, guidHex: opened.guidHex)
        if let counts { db.merge(counts) }

        let snapshot = ArtworkSnapshot.capture(artworkDir: artworkDir, dbURL: artworkDBURL)
        var copied: [URL] = []
        var createdDirs: [URL] = []
        var artwork: ArtworkDB?
        do {
            var used = Set(db.tracks.map { $0.location.lowercased() })
            var staged: [(NewTrack, MediaInfo)] = []
            for (index, (info, file)) in prepared.enumerated() {
                try Task.checkCancellation()
                progress(SyncProgress(phase: "Copying", current: index + 1, total: prepared.count, fraction: Double(index) / Double(prepared.count), item: info.url.deletingPathExtension().lastPathComponent + "." + file.ext))
                if case .duringCopy(let at) = fault, at == index { throw SyncError.ioFailure("fault") }
                let (location, destination) = try place(ext: file.ext, used: &used, createdDirs: &createdDirs)
                do { try FileManager.default.copyItem(at: file.url, to: destination) } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw SyncError.ioFailure("couldn't copy \(info.url.lastPathComponent): \(error)")
                }
                copied.append(destination)
                staged.append((Self.newTrack(info, file, location), info))
            }
            if fault == .afterCopyBeforeDB { throw SyncError.ioFailure("fault") }

            var covers: [String: (id: UInt32, size: UInt32)] = [:]
            var newIds: [UInt32] = []
            for (newTrack, info) in staged {
                let track = db.add(newTrack)
                newIds.append(track.id)
                guard let data = CoverLocator.cover(for: info) else { continue }
                let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if let hit = covers[digest] {
                    db.setArtwork(trackId: track.id, artworkId: hit.id, size: hit.size)
                } else if let image = Self.decode(data) {
                    let target = try artwork ?? loadArtwork()
                    artwork = target
                    let added = try target.add(cover: image, sourceByteCount: UInt32(truncatingIfNeeded: data.count), songDbId: track.dbid, artworkDir: artworkDir)
                    covers[digest] = (added.imageId, added.sourceSize)
                    db.setArtwork(trackId: track.id, artworkId: added.imageId, size: added.sourceSize)
                }
            }
            try ensureUnchanged(opened.original)
            try persist(db: db, artwork: artwork, guid: opened.guid, progress: progress)
            let idSet = Set(newIds)
            report.added = db.tracks.filter { idSet.contains($0.id) }
        } catch {
            rollback(copied: copied, createdDirs: createdDirs, snapshot: snapshot, artworkTouched: artwork != nil)
            throw error
        }
        report.warnings += finishPlayCounts(merged: counts != nil)
        return report
    }

    public func remove(ids: Set<UInt32>) async throws -> SyncReport {
        let opened = try openForWrite()
        let db = opened.db
        let targets = db.tracks.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return SyncReport() }
        let counts = try parsePlayCounts()
        try Backup.perform(controlDir: control, backupsRoot: backupsRoot, guidHex: opened.guidHex)
        if let counts { db.merge(counts) }

        let snapshot = ArtworkSnapshot.capture(artworkDir: artworkDir, dbURL: artworkDBURL)
        var artwork: ArtworkDB?
        do {
            db.remove(ids: Set(targets.map(\.id)))
            let remaining = Set(db.tracks.compactMap(\.artworkId))
            let drop = Set(targets.compactMap(\.artworkId)).subtracting(remaining)
            if !drop.isEmpty, FileManager.default.fileExists(atPath: artworkDBURL.path) {
                let target = try loadArtwork()
                target.remove(imageIds: drop)
                artwork = target
            }
            try ensureUnchanged(opened.original)
            try persist(db: db, artwork: artwork, guid: opened.guid, progress: { _ in })
        } catch {
            rollback(copied: [], createdDirs: [], snapshot: snapshot, artworkTouched: artwork != nil)
            throw error
        }
        var warnings: [String] = []
        for track in targets {
            guard let file = physical(track.location) else {
                warnings.append("Invalid location, audio not deleted for \(track.title): \(track.location)")
                continue
            }
            do { try FileManager.default.removeItem(at: file) } catch {
                warnings.append("Couldn't delete audio for \(track.title) (\(file.lastPathComponent)): \(error.localizedDescription)")
            }
        }
        warnings += finishPlayCounts(merged: counts != nil)
        return SyncReport(removed: targets.count, warnings: warnings)
    }

    private struct Opened {
        let db: ITunesDB
        let guid: [UInt8]
        let original: Data
        var guidHex: String { guid.map { String(format: "%02X", $0) }.joined() }
    }

    private func ensureUnchanged(_ original: Data) throws {
        guard try readDB() == original else { throw SyncError.databaseChanged }
    }

    private func readDB() throws -> Data {
        do { return try Data(contentsOf: dbURL) } catch { throw SyncError.ioFailure("couldn't read the iTunesDB: \(error)") }
    }

    private func openForWrite() throws -> Opened {
        let data = try readDB()
        guard let parsed = try? Chunk.parse(data), parsed.serialize() == data else { throw SyncError.roundTripMismatch }
        guard let db = try? ITunesDB(data: data) else { throw SyncError.roundTripMismatch }
        let guid: [UInt8]
        if let override = guidOverride {
            guard Hash58.verify(data, guid: override) else { throw SyncError.guidUnverified }
            guid = override
        } else {
            do { guid = try GUIDResolver.resolve(for: device, existingDB: data) } catch DeviceError.guidUnverified {
                throw SyncError.guidUnverified
            } catch {
                throw SyncError.ioFailure("GUID: \(error)")
            }
        }
        return Opened(db: db, guid: guid, original: data)
    }

    private func parsePlayCounts() throws -> [PlayCountEntry]? {
        guard FileManager.default.fileExists(atPath: playCountsURL.path) else { return nil }
        do { return try PlayCounts.parse(Data(contentsOf: playCountsURL)) } catch {
            throw SyncError.ioFailure("Play Counts unreadable: \(error)")
        }
    }

    private func finishPlayCounts(merged: Bool) -> [String] {
        guard merged else { return [] }
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: playCountsURL.path + ".bak")
        try? fm.removeItem(at: backup)
        do { try fm.moveItem(at: playCountsURL, to: backup) } catch {
            return ["Couldn't rename Play Counts to Play Counts.bak: \(error.localizedDescription)"]
        }
        return []
    }

    private func loadArtwork() throws -> ArtworkDB {
        guard FileManager.default.fileExists(atPath: artworkDBURL.path) else { return ArtworkDB.makeEmpty() }
        do { return try ArtworkDB(data: Data(contentsOf: artworkDBURL)) } catch {
            throw SyncError.ioFailure("ArtworkDB not recognized: \(error)")
        }
    }

    private func persist(db: ITunesDB, artwork: ArtworkDB?, guid: [UInt8], progress: @Sendable (SyncProgress) -> Void) throws {
        progress(SyncProgress(phase: "Saving", current: 1, total: 1, fraction: 0))
        if let artwork {
            try FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
            try AtomicWrite.replace(artworkDBURL, with: artwork.serialize())
        }
        var out = db.serialize()
        try Hash58.sign(&out, guid: guid)
        let injected = fault == .duringDBWrite
        try AtomicWrite.replace(dbURL, with: out, beforeRename: {
            if injected { throw SyncError.ioFailure("fault") }
        })
        progress(SyncProgress(phase: "Saving", current: 1, total: 1, fraction: 1))
    }

    private func rollback(copied: [URL], createdDirs: [URL], snapshot: ArtworkSnapshot, artworkTouched: Bool) {
        let fm = FileManager.default
        for file in copied { try? fm.removeItem(at: file) }
        for dir in createdDirs.reversed() { try? fm.removeItem(at: dir) }
        if artworkTouched { snapshot.restore(artworkDir: artworkDir, dbURL: artworkDBURL) }
    }

    private func prepare(_ info: MediaInfo) async throws -> PreparedFile {
        let work = workDir
        return try await Task.detached { try await Transcoder.prepare(info, workDir: work, progress: { _ in }) }.value
    }

    private func place(ext: String, used: inout Set<String>, createdDirs: inout [URL]) throws -> (String, URL) {
        let fm = FileManager.default
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for _ in 0..<2000 {
            let folder = String(format: "F%02d", Int.random(in: 0...49))
            let name = String((0..<4).map { _ in letters.randomElement()! })
            let location = ":iPod_Control:Music:\(folder):\(name).\(ext)"
            if used.contains(location.lowercased()) { continue }
            let dir = control.appendingPathComponent("Music/\(folder)", isDirectory: true)
            let destination = dir.appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: destination.path) { continue }
            if !fm.fileExists(atPath: dir.path) {
                do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
                    throw SyncError.ioFailure("couldn't create \(folder): \(error)")
                }
                createdDirs.append(dir)
            }
            used.insert(location.lowercased())
            return (location, destination)
        }
        throw SyncError.ioFailure("sin nombres libres en Music")
    }

    private func physical(_ location: String) -> URL? {
        let parts = location.split(separator: ":").map(String.init)
        guard parts.count >= 3, parts[0] == "iPod_Control", parts[1] == "Music", !parts.contains("..") else { return nil }
        return device.volume.appendingPathComponent(parts.joined(separator: "/"))
    }

    private static func newTrack(_ info: MediaInfo, _ file: PreparedFile, _ location: String) -> NewTrack {
        NewTrack(
            title: info.title, artist: info.artist, album: info.album, albumArtist: info.albumArtist, genre: info.genre,
            filetype: file.filetype, location: location, trackNumber: info.trackNumber, trackCount: info.trackCount,
            discNumber: info.discNumber, discCount: info.discCount, year: info.year, durationMs: file.durationMs,
            size: file.sizeBytes, bitrate: file.bitrateKbps, sampleRate: file.sampleRate)
    }

    private static func key(_ artist: String, _ album: String, _ title: String, _ number: Int) -> String {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return [fold(artist), fold(album), fold(title), String(number)].joined(separator: "\u{1}")
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { result.append(url); continue }
            guard isDir.boolValue else { result.append(url); continue }
            let found = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL }
                .filter { supportedExtensions.contains($0.pathExtension.lowercased()) } ?? []
            result += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return result
    }
}

struct ArtworkSnapshot {
    let dbBytes: Data?
    let dirExisted: Bool
    let ithmbSizes: [String: UInt64]

    static func capture(artworkDir: URL, dbURL: URL) -> ArtworkSnapshot {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: artworkDir.path, isDirectory: &isDir) && isDir.boolValue
        var sizes: [String: UInt64] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: artworkDir.path)) ?? [] where name.hasSuffix(".ithmb") {
            let size = (try? fm.attributesOfItem(atPath: artworkDir.appendingPathComponent(name).path))?[.size] as? NSNumber
            sizes[name] = size?.uint64Value ?? 0
        }
        return ArtworkSnapshot(dbBytes: try? Data(contentsOf: dbURL), dirExisted: exists, ithmbSizes: sizes)
    }

    func restore(artworkDir: URL, dbURL: URL) {
        let fm = FileManager.default
        guard dirExisted else { try? fm.removeItem(at: artworkDir); return }
        if let dbBytes { try? AtomicWrite.replace(dbURL, with: dbBytes) } else { try? fm.removeItem(at: dbURL) }
        for name in (try? fm.contentsOfDirectory(atPath: artworkDir.path)) ?? [] where name.hasSuffix(".ithmb") {
            let url = artworkDir.appendingPathComponent(name)
            guard let size = ithmbSizes[name] else { try? fm.removeItem(at: url); continue }
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: size)
                try? handle.close()
            }
        }
    }
}
