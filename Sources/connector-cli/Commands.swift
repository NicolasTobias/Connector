import Foundation
import ConnectorCore

func runInfo(_ d: IPodDevice) throws {
    print("Volume: \(d.volume.path)")
    print("Volume name: \(d.name)")
    if let db = try readFile(dbURL(d)), let name = try? ITunesDB(data: db).deviceName { print("iPod name: \(name)") }
    print("Model: \(d.modelNumber ?? "unknown")")
    print("Capacity: \(gigabytes(d.capacityBytes))")
    print("Free: \(gigabytes(d.freeBytes))")
    print("GUID candidates: \(GUIDResolver.candidates(for: d).count)")
    if let db = try readFile(dbURL(d)) {
        if let guid = try? GUIDResolver.resolve(for: d, existingDB: db) {
            print("GUID verified: yes")
            print("GUID: \(hex(guid))")
        } else {
            print("GUID verified: no")
        }
    } else {
        print("GUID verified: no (no iTunesDB)")
    }
}

func runVerify(_ d: IPodDevice) throws {
    guard let db = try readFile(dbURL(d)) else { throw CLIError("No iTunesDB at \(dbURL(d).path).") }
    var ok = true
    let guid = try? GUIDResolver.resolve(for: d, existingDB: db)
    print("GUID verified: \(guid != nil ? "yes" : "no")")
    let signed = guid.map { Hash58.verify(db, guid: $0) } ?? false
    print("hash58 signature: \(signed ? "valid" : "invalid")")
    ok = ok && guid != nil && signed

    let cycle = roundTripReport("iTunesDB", db)
    cycle.lines.forEach { print($0) }
    ok = ok && cycle.ok

    do {
        if let art = try readFile(artworkURL(d)) {
            let artCycle = roundTripReport("ArtworkDB", art)
            artCycle.lines.forEach { print($0) }
            ok = ok && artCycle.ok
        } else {
            print("ArtworkDB cycle: no ArtworkDB")
        }
    } catch {
        print("ArtworkDB cycle: unreadable (\(error))")
        ok = false
    }

    do {
        let parsed = try ITunesDB(data: db)
        print("iTunesDB parseable: yes")
        print("Tracks: \(parsed.tracks.count)")
    } catch {
        print("iTunesDB parseable: no (\(error))")
        ok = false
    }
    if !ok { throw CLIError("Verification failed.") }
}

func runList(_ d: IPodDevice) async throws {
    let tracks = try await SyncSession(device: d).load()
    for t in tracks {
        print("\(t.id)\t\(t.artist) — \(t.title)\t\(t.album)\t\(duration(ms: t.durationMs))")
    }
}

func runExport(_ d: IPodDevice, destination: String) throws {
    let fm = FileManager.default
    let dest = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath).standardizedFileURL
    if let existing = try? fm.contentsOfDirectory(atPath: dest.path), !existing.isEmpty {
        throw CLIError("\(dest.path) already exists and is not empty.")
    }
    let volumePath = d.volume.standardizedFileURL.path
    if dest.path == volumePath || dest.path.hasPrefix(volumePath + "/") {
        throw CLIError("The destination can't be inside the iPod.")
    }
    let target = dest.appendingPathComponent("iPod_Control", isDirectory: true)
    let createdDestination = !fm.fileExists(atPath: dest.path)
    do {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: d.controlDir.path) where name != "Music" {
            try fm.copyItem(at: d.controlDir.appendingPathComponent(name), to: target.appendingPathComponent(name))
        }
    } catch {
        try? fm.removeItem(at: createdDestination ? dest : target)
        throw error
    }
    let db = try readFile(dbURL(d))
    let guid = try? GUIDResolver.resolve(for: d, existingDB: db)
    let guidHex = guid.map(hex) ?? ""
    try Data(guidHex.utf8).write(to: dest.appendingPathComponent("GUID.txt"))
    print("Exported to: \(target.path)")
    print("export CONNECTOR_REAL_IPOD_CONTROL=\(target.path)")
    print("export CONNECTOR_REAL_GUID=\(guidHex)")
    if guid == nil { print("Warning: couldn't resolve the GUID; GUID.txt is empty.") }
}

func printReport(_ r: SyncReport) {
    print("Added: \(r.added.count)")
    for t in r.added { print("  \(t.id)\t\(t.artist) — \(t.title)") }
    print("Duplicates skipped: \(r.skippedDuplicates.count)")
    for u in r.skippedDuplicates { print("  \(u.path)") }
    print("Failed: \(r.failed.count)")
    for (u, reason) in r.failed { print("  \(u.path): \(reason)") }
    print("Removed: \(r.removed)")
    for w in r.warnings { print("Warning: \(w)") }
}

func runAdd(_ d: IPodDevice, paths: [String]) async throws {
    guard !paths.isEmpty else { throw CLIError("Provide at least one path to add.") }
    let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let report = try await SyncSession(device: d).add(urls) { p in
        print("\(p.phase) \(p.current)/\(p.total) (\(Int(p.fraction * 100))%)")
    }
    printReport(report)
}

func runRemove(_ d: IPodDevice, ids: [String]) async throws {
    guard !ids.isEmpty else { throw CLIError("Provide at least one id to remove.") }
    let parsed = try ids.map { raw -> UInt32 in
        guard let id = UInt32(raw) else { throw CLIError("Invalid id: \(raw)") }
        return id
    }
    printReport(try await SyncSession(device: d).remove(ids: Set(parsed)))
}

func runEject(_ d: IPodDevice) async throws {
    try await Ejector.eject(d)
    print("iPod ejected: \(d.name)")
}
