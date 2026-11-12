import Foundation
import Observation

public struct LogEntry: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable { case info, ok, skip, error }
    public let id: Int
    public let date: Date
    public let kind: Kind
    public let text: String

    public init(id: Int, date: Date = Date(), kind: Kind, text: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
    }
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var device: IPodDevice?
    public private(set) var tracks: [Track] = []
    public var selection: Set<UInt32> = []
    public private(set) var progress: SyncProgress?
    public private(set) var lastReport: SyncReport?
    public var error: String?
    public private(set) var busy = false
    public private(set) var log: [LogEntry] = []
    public private(set) var queued = 0
    public private(set) var deviceName: String?
    public private(set) var albums: [AlbumGroup] = []
    public private(set) var rows: [LibraryRow] = []
    public private(set) var sort: LibrarySort = .album
    public private(set) var collapsed: Set<String> = []

    @ObservationIgnored private let volumesRoot: URL
    @ObservationIgnored private let backupsRoot: URL
    @ObservationIgnored private let guidOverride: [UInt8]?
    @ObservationIgnored private var logCounter = 0
    @ObservationIgnored private var queue: [[URL]] = []
    @ObservationIgnored private var anchor: UInt32?
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var lastLoggedPhase = ""
    @ObservationIgnored private var lastLoggedKey = ""

    public init(
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes"),
        backupsRoot: URL = SyncSession.defaultBackupsRoot,
        guidOverride: [UInt8]? = nil
    ) {
        self.volumesRoot = volumesRoot
        self.backupsRoot = backupsRoot
        self.guidOverride = guidOverride
    }

    public var displayName: String { deviceName ?? device?.name ?? "iPod" }

    public var canAdd: Bool { device != nil }
    public var canRemove: Bool { device != nil && !busy && !draining && !selection.isEmpty }
    public var canEject: Bool { device != nil && !busy && !draining }

    public var usedBytes: Int64 {
        guard let device else { return 0 }
        return max(0, device.capacityBytes - device.freeBytes)
    }

    public var usedFraction: Double {
        guard let device, device.capacityBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(device.capacityBytes)))
    }

    public func setPreview(device: IPodDevice?, tracks: [Track], selection: Set<UInt32> = [], progress: SyncProgress? = nil, report: SyncReport? = nil, log: [LogEntry] = [], deviceName: String? = nil) {
        self.log = log
        self.deviceName = deviceName
        self.device = device
        self.tracks = tracks
        self.selection = selection
        self.progress = progress
        self.lastReport = report
        collapsed = []
        rebuildRows()
    }

    public func setSort(_ value: LibrarySort) {
        sort = value
        rebuildRows()
    }

    public func collapseAll() {
        collapsed = Set(albums.map(\.id))
        rebuildRows()
    }

    public func expandAll() {
        collapsed = []
        rebuildRows()
    }

    public func toggleExpanded(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        rebuildRows()
    }

    public func clickTrack(_ id: UInt32, shift: Bool, command: Bool) {
        let visible = rows.compactMap { row -> UInt32? in
            if case .track(let track, _) = row { return track.id }
            return nil
        }
        if shift, let anchor, let a = visible.firstIndex(of: anchor), let b = visible.firstIndex(of: id) {
            selection = Set(visible[min(a, b)...max(a, b)])
        } else if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            selection = [id]
            anchor = id
        }
    }

    public func clickAlbum(_ id: String, command: Bool) {
        guard let group = albums.first(where: { $0.id == id }) else { return }
        let ids = group.trackIDs
        if command {
            if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
        } else {
            selection = ids
        }
        anchor = nil
    }

    private func rebuildRows() {
        albums = Library.sorted(Library.groups(from: tracks), by: sort)
        collapsed.formIntersection(Set(albums.map(\.id)))
        rows = Library.rows(groups: albums, collapsed: collapsed)
    }

    public func refreshDevice() {
        let previous = device?.volume.standardizedFileURL
        let found = IPodDevice.discover(in: volumesRoot)
        let current = found.first(where: { $0.volume.standardizedFileURL == previous }) ?? found.first
        device = current
        if current?.volume.standardizedFileURL != previous {
            tracks = []
            deviceName = nil
            selection = []
            lastReport = nil
            rebuildRows()
            if current != nil { Task { await reloadTracks() } }
        }
    }

    public func reloadTracks() async {
        guard let device else {
            tracks = []
            deviceName = nil
            selection = []
            rebuildRows()
            return
        }
        do {
            let library = try await makeSession(device).loadLibrary()
            tracks = library.tracks
            deviceName = library.deviceName
            selection = selection.intersection(Set(library.tracks.map(\.id)))
        } catch {
            tracks = []
            deviceName = nil
            selection = []
            self.error = Self.message(for: error)
        }
        rebuildRows()
    }

    public func add(_ urls: [URL]) async {
        guard device != nil, !urls.isEmpty else { return }
        if busy || draining {
            queue.append(urls)
            queued = queue.count
            note(.info, "Queued: \(urls.count) \(urls.count == 1 ? "item" : "items")")
            return
        }
        draining = true
        defer { draining = false }
        var next: [URL]? = urls
        while let batch = next {
            guard let current = freshDevice() else { queue.removeAll(); queued = 0; return }
            await run(title: "Adding \(batch.count) \(batch.count == 1 ? "item" : "items")", device: current) { session, report in
                try await session.add(batch, progress: report)
            }
            next = queue.isEmpty ? nil : queue.removeFirst()
            queued = queue.count
        }
    }

    public func removeSelected() async {
        guard canRemove, let current = freshDevice() else { return }
        let ids = selection
        let names = tracks.filter { ids.contains($0.id) }.map { "\($0.artist) — \($0.title)" }
        await run(title: "Deleting \(names.count) \(names.count == 1 ? "song" : "songs")", device: current, detail: { [weak self] report in
            guard report.removed > 0 else { return }
            for name in names { self?.note(.ok, "Deleted: \(name)") }
        }) { session, _ in
            try await session.remove(ids: ids)
        }
    }

    public func eject() async {
        guard canEject, let device else { return }
        busy = true
        defer { busy = false }
        do {
            try await Ejector.eject(device)
            self.device = nil
            tracks = []
            deviceName = nil
            selection = []
            lastReport = nil
            rebuildRows()
        } catch {
            self.error = Self.message(for: error)
        }
    }

    public var reportText: String? {
        guard let report = lastReport else { return nil }
        var parts: [String] = []
        if !report.added.isEmpty { parts.append("Added: \(report.added.count)") }
        if report.removed > 0 { parts.append("Deleted: \(report.removed)") }
        if !report.skippedDuplicates.isEmpty { parts.append("Duplicates skipped: \(report.skippedDuplicates.count)") }
        if !report.failed.isEmpty {
            let names = report.failed.map { $0.0.lastPathComponent }.joined(separator: ", ")
            parts.append("Failed: \(report.failed.count) (\(names))")
        }
        if !report.warnings.isEmpty { parts.append("Warnings: \(report.warnings.count)") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }

    private func run(
        title: String,
        device current: IPodDevice,
        detail: @MainActor (SyncReport) -> Void = { _ in },
        _ operation: @Sendable (SyncSession, @escaping @Sendable (SyncProgress) -> Void) async throws -> SyncReport
    ) async {
        busy = true
        error = nil
        progress = nil
        log = []
        lastLoggedPhase = ""
        lastLoggedKey = ""
        note(.info, title)
        let session = makeSession(current)
        let report: @Sendable (SyncProgress) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.busy else { return }
                self.progress = value
                self.logProgress(value)
            }
        }
        var finished: SyncReport?
        do {
            let result = try await operation(session, report)
            lastReport = result
            finished = result
            detail(result)
            logResult(result)
        } catch {
            let text = Self.message(for: error)
            self.error = text
            note(.error, "Error: \(text)")
        }
        busy = false
        progress = nil
        refreshDevice()
        await reloadTracks()
        if let added = finished?.added, !added.isEmpty {
            let ids = Set(added.map(\.id))
            let shown = Set(tracks.filter { ids.contains($0.id) }.map(Library.key(of:)))
            collapsed.subtract(shown)
            rebuildRows()
        }
    }

    private func note(_ kind: LogEntry.Kind, _ text: String) {
        logCounter += 1
        log.append(LogEntry(id: logCounter, kind: kind, text: text))
    }

    private func logProgress(_ value: SyncProgress) {
        if let item = value.item {
            let key = "\(value.phase)|\(value.current)"
            guard key != lastLoggedKey else { return }
            lastLoggedKey = key
            lastLoggedPhase = value.phase
            note(.info, "\(value.phase) \(value.current)/\(value.total): \(item)")
        } else if value.phase != lastLoggedPhase {
            lastLoggedPhase = value.phase
            note(.info, "\(value.phase)…")
        }
    }

    private func logResult(_ result: SyncReport) {
        for track in result.added { note(.ok, "Added: \(track.artist) — \(track.title)") }
        for url in result.skippedDuplicates { note(.skip, "Duplicate, skipped: \(url.lastPathComponent)") }
        for (url, reason) in result.failed { note(.error, "Failed: \(url.lastPathComponent) — \(reason)") }
        for warning in result.warnings { note(.error, "Warning: \(warning)") }
        note(.info, "Done. \(reportText ?? "No changes")")
    }

    public var logText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return log.map { "\(formatter.string(from: $0.date))  \($0.text)" }.joined(separator: "\n")
    }

    private func freshDevice() -> IPodDevice? {
        guard let device else { return nil }
        let found = IPodDevice.discover(in: volumesRoot)
        return found.first(where: { $0.volume.standardizedFileURL == device.volume.standardizedFileURL }) ?? device
    }

    private func makeSession(_ device: IPodDevice) -> SyncSession {
        SyncSession(device: device, backupsRoot: backupsRoot, guidOverride: guidOverride)
    }

    static func message(for error: Error) -> String {
        switch error {
        case let SyncError.notEnoughSpace(needed, free):
            let f = ByteCountFormatter()
            return "Not enough space on the iPod: \(f.string(fromByteCount: needed)) needed, \(f.string(fromByteCount: free)) free."
        case SyncError.databaseChanged:
            return "The iPod's database changed during the operation. Nothing was written; try again."
        case SyncError.roundTripMismatch:
            return "The iPod's database isn't recognized. Nothing was written."
        case SyncError.guidUnverified, DeviceError.guidUnverified:
            return "Couldn't verify the iPod's signature. Nothing was written."
        case let SyncError.ioFailure(text):
            return "Write error: \(text)"
        case DeviceError.noGUID:
            return "Couldn't get the iPod's identifier."
        case let DeviceError.ejectFailed(text):
            return "Couldn't eject the iPod: \(text)"
        default:
            return error.localizedDescription
        }
    }
}
