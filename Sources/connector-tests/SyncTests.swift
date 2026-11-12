import Foundation
import ConnectorCore

enum SyncTests {
    static let guid: [UInt8] = [0x00, 0x0A, 0x27, 0x00, 0x12, 0x34, 0x56, 0x78]

    struct Pod {
        let root: URL
        let backups: URL
        let work: URL
        let device: IPodDevice
        var control: URL { root.appendingPathComponent("iPod_Control") }
        var dbURL: URL { control.appendingPathComponent("iTunes/iTunesDB") }

        func plainSession() -> SyncSession {
            SyncSession(device: device, backupsRoot: backups, workDir: work)
        }

        func session(fault: FaultPoint? = nil) -> SyncSession {
            SyncSession(device: device, backupsRoot: backups, workDir: work, guidOverride: guid, faultInjection: fault)
        }
    }

    static func makePod(freeBytes: Int64 = 10_000_000_000, mutate: (inout Data) -> Void = { _ in }) throws -> Pod {
        let base = try tempDir()
        let root = base.appendingPathComponent("pod")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("iPod_Control/iTunes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("iPod_Control/Music"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("iPod_Control/Device"), withIntermediateDirectories: true)
        try Data("info".utf8).write(to: root.appendingPathComponent("iPod_Control/Device/SysInfo"))
        var db = ITunesDB.makeEmpty().serialize()
        try Hash58.sign(&db, guid: guid)
        mutate(&db)
        try db.write(to: root.appendingPathComponent("iPod_Control/iTunes/iTunesDB"))
        let device = IPodDevice(volume: root, name: "Test", modelNumber: nil, capacityBytes: 80_000_000_000, freeBytes: freeBytes)
        return Pod(root: root, backups: base.appendingPathComponent("Backups"), work: base.appendingPathComponent("work"), device: device)
    }

    static func snapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return result }
        for case let url as URL in e {
            let isDir = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
            let key = String(url.path.dropFirst(root.path.count))
            if isDir { result[key + "/"] = Data(); continue }
            let size = ((try fm.attributesOfItem(atPath: url.path))[.size] as? NSNumber)?.intValue ?? 0
            result[key] = size > 10_000_000 ? Data("tamaño:\(size)".utf8) : try Data(contentsOf: url)
        }
        return result
    }

    static func flac(_ dir: URL, _ name: String, title: String, album: String = "Album", cover: Data? = nil, track: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try makeFLAC(at: url, rate: 96000, bits: 24, tags: ["TITLE": title, "ARTIST": "Artista", "ALBUM": album, "TRACKNUMBER": "\(track)"], picture: cover)
        return url
    }

    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)]) }

    static func syncError(_ body: () async throws -> Void) async -> SyncError? {
        do { try await body() } catch let e as SyncError { return e } catch {}
        return nil
    }

    static let all: [TestCase] = [
        TestCase(name: "sync: añadir flac aparece con carátula") {
            let pod = try makePod()
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno", cover: makeJPEG(size: 600))
            let session = pod.session()
            let report = try await session.add([url], progress: { _ in })
            expectEqual(report.added.count, 1)
            let tracks = try await session.load()
            expectEqual(tracks.count, 1)
            expectEqual(tracks.first?.filetype ?? "", "Apple Lossless audio file")
            expect(tracks.first?.artworkId != nil, "artworkId")
            let location = tracks.first?.location ?? ""
            let comps = location.split(separator: ":").map(String.init)
            expectEqual(comps.first ?? "", "iPod_Control")
            let physical = pod.root.appendingPathComponent(comps.joined(separator: "/"))
            expect(FileManager.default.fileExists(atPath: physical.path), "fichero \(physical.path)")
            expect(location.hasPrefix(":iPod_Control:Music:F"), location)
            let db = try Data(contentsOf: pod.dbURL)
            expect(Hash58.verify(db, guid: guid), "hash58")
            let art = try ArtworkDB(data: Data(contentsOf: pod.control.appendingPathComponent("Artwork/ArtworkDB")))
            expectEqual(art.imageIds.count, 1)
        },
        TestCase(name: "sync: duplicado se omite") {
            let pod = try makePod()
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno")
            let report = try await pod.session().add([url, url], progress: { _ in })
            expectEqual(report.added.count, 1)
            expectEqual(report.skippedDuplicates.count, 1)
        },
        TestCase(name: "sync: fichero ilegible no aborta el lote") {
            let pod = try makePod()
            let src = try tempDir()
            let a = try flac(src, "a.flac", title: "Uno")
            let b = try flac(src, "b.flac", title: "Dos")
            let c = try flac(src, "c.flac", title: "Tres")
            try Data(contentsOf: b).prefix(10).write(to: b)
            let report = try await pod.session().add([a, b, c], progress: { _ in })
            expectEqual(report.added.count, 2)
            expectEqual(report.failed.count, 1)
            expectEqual(report.failed.first?.0, b)
        },
        TestCase(name: "sync: sin espacio no escribe nada") {
            let pod = try makePod(freeBytes: 1_000_000)
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno")
            let before = try snapshot(pod.root)
            let error = await syncError { _ = try await pod.session().add([url], progress: { _ in }) }
            if case .notEnoughSpace = error {} else { expect(false, "esperaba notEnoughSpace, obtuve \(String(describing: error))") }
            expect(try snapshot(pod.root) == before, "el iPod cambió")
            expect(!FileManager.default.fileExists(atPath: pod.backups.path), "no debe haber copias")
        },
        TestCase(name: "sync: la base cambió durante la conversión no se pisa") {
            let pod = try makePod()
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno")
            let before = try snapshot(pod.root)
            let error = await syncError { _ = try await pod.session(fault: .touchDatabaseAfterConversion).add([url], progress: { _ in }) }
            if case .databaseChanged = error {} else { expect(false, "esperaba databaseChanged, obtuve \(String(describing: error))") }
            let after = try snapshot(pod.root)
            expectEqual(after.keys.filter { $0.contains("Music") }.sorted(), before.keys.filter { $0.contains("Music") }.sorted())
            expect(!after.keys.contains { $0.contains("tmp-connector") }, "quedó un temporal")
            expect(!FileManager.default.fileExists(atPath: pod.backups.path), "no debe haber copias")
        },
        TestCase(name: "sync: fallo durante la escritura deja la base intacta") {
            let pod = try makePod()
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno", cover: makeJPEG(size: 600))
            let before = try snapshot(pod.root)
            let error = await syncError { _ = try await pod.session(fault: .duringDBWrite).add([url], progress: { _ in }) }
            expect(error != nil, "se esperaba un error")
            let after = try snapshot(pod.root)
            expect(after == before, "diferencias: \(Set(after.keys).symmetricDifference(Set(before.keys)))")
            expect(!after.keys.contains { $0.contains(".tmp-connector") }, "queda temporal")
        },
        TestCase(name: "sync: fallo tras copiar deja el iPod intacto") {
            let pod = try makePod()
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno", cover: makeJPEG(size: 600))
            let before = try snapshot(pod.root)
            let error = await syncError { _ = try await pod.session(fault: .afterCopyBeforeDB).add([url], progress: { _ in }) }
            expect(error != nil, "se esperaba un error")
            expect(try snapshot(pod.root) == before, "el iPod cambió")
        },
        TestCase(name: "sync: borrar elimina fichero tras guardar") {
            let pod = try makePod()
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno")
            let session = pod.session()
            let report = try await session.add([url], progress: { _ in })
            let track = try require(report.added.first)
            let comps = track.location.split(separator: ":").map(String.init)
            let physical = pod.root.appendingPathComponent(comps.joined(separator: "/"))
            expect(FileManager.default.fileExists(atPath: physical.path))
            let removal = try await session.remove(ids: [track.id])
            expectEqual(removal.removed, 1)
            expect(!FileManager.default.fileExists(atPath: physical.path), "el fichero sigue")
            expectEqual(try await session.load().count, 0)
            expect(Hash58.verify(try Data(contentsOf: pod.dbURL), guid: guid), "hash58")
        },
        TestCase(name: "sync: base no reconocida no se toca") {
            let pod = try makePod(mutate: { $0.append(0xAB) })
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno")
            let before = try snapshot(pod.root)
            let error = await syncError { _ = try await pod.session().add([url], progress: { _ in }) }
            if case .roundTripMismatch = error {} else { expect(false, "esperaba roundTripMismatch, obtuve \(String(describing: error))") }
            expect(try snapshot(pod.root) == before, "el iPod cambió")
        },
        TestCase(name: "sync: copia inicial sin Music") {
            let pod = try makePod()
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno")
            _ = try await pod.session().add([url], progress: { _ in })
            let hex = guid.map { String(format: "%02X", $0) }.joined()
            let initial = pod.backups.appendingPathComponent("\(hex)/inicial")
            expect(FileManager.default.fileExists(atPath: initial.appendingPathComponent("iTunes/iTunesDB").path), "falta iTunesDB")
            expect(!FileManager.default.fileExists(atPath: initial.appendingPathComponent("Music").path), "no debe copiar Music")
            let stamps = try FileManager.default.contentsOfDirectory(atPath: pod.backups.appendingPathComponent(hex).path).filter { $0 != "inicial" }
            expectEqual(stamps.count, 1)
        },
        TestCase(name: "sync: caratula compartida del álbum se añade una vez") {
            let pod = try makePod()
            let src = try tempDir()
            let cover = makeJPEG(size: 600)
            let urls = try (1...3).map { try flac(src, "t\($0).flac", title: "Pista \($0)", cover: cover, track: $0) }
            let session = pod.session()
            let report = try await session.add(urls, progress: { _ in })
            expectEqual(report.added.count, 3)
            let art = try ArtworkDB(data: Data(contentsOf: pod.control.appendingPathComponent("Artwork/ArtworkDB")))
            expectEqual(art.imageIds.count, 1)
            let ids = Set(try await session.load().compactMap(\.artworkId))
            expectEqual(ids.count, 1)
            expectEqual(try await session.load().filter { $0.artworkId != nil }.count, 3)
        },
        TestCase(name: "sync: borrar una pista deja la carátula si otra del álbum la usa") {
            let pod = try makePod()
            let src = try tempDir()
            let cover = makeJPEG(size: 600)
            let urls = try (1...3).map { try flac(src, "t\($0).flac", title: "Pista \($0)", cover: cover, track: $0) }
            let session = pod.session()
            _ = try await session.add(urls, progress: { _ in })
            let tracks = try await session.load()
            let artworkURL = pod.control.appendingPathComponent("Artwork/ArtworkDB")
            func imageCount() throws -> Int {
                let data = try Data(contentsOf: artworkURL)
                let art = try ArtworkDB(data: data)
                return art.imageIds.count
            }
            _ = try await session.remove(ids: [tracks[0].id, tracks[1].id])
            expectEqual(try imageCount(), 1)
            _ = try await session.remove(ids: [tracks[2].id])
            expectEqual(try imageCount(), 0)
        },
        TestCase(name: "sync: Play Counts se fusiona y renombra") {
            let pod = try makePod()
            let src = try tempDir()
            let session = pod.session()
            _ = try await session.add([try flac(src, "a.flac", title: "Uno")], progress: { _ in })
            let counts = pod.control.appendingPathComponent("iTunes/Play Counts")
            var data = Data("mhdp".utf8)
            data += le32(16) + le32(12) + le32(1)
            data += le32(5) + le32(0) + le32(0)
            try data.write(to: counts)
            _ = try await session.add([try flac(src, "b.flac", title: "Dos")], progress: { _ in })
            let tracks = try await session.load()
            expectEqual(tracks.first { $0.title == "Uno" }?.playCount ?? 0, 5)
            expect(!FileManager.default.fileExists(atPath: counts.path), "Play Counts sigue")
            expect(FileManager.default.fileExists(atPath: counts.path + ".bak"), "falta .bak")
        },
        TestCase(name: "sync: fallo en el 2º add con Artwork previo restaura ArtworkDB e ithmb") {
            for rotate in [false, true] {
                let pod = try makePod()
                let src = try tempDir()
                _ = try await pod.session().add([try flac(src, "a.flac", title: "Uno", album: "A", cover: makeJPEG(size: 600))], progress: { _ in })
                let artDir = pod.control.appendingPathComponent("Artwork")
                let ithmbs = try FileManager.default.contentsOfDirectory(atPath: artDir.path).filter { $0.hasSuffix("_1.ithmb") }
                expect(!ithmbs.isEmpty, "sin ithmb previo")
                if rotate {
                    for name in ithmbs {
                        let h = try FileHandle(forWritingTo: artDir.appendingPathComponent(name))
                        try h.truncate(atOffset: 256_000_000)
                        try h.close()
                    }
                }
                let before = try snapshot(pod.root)
                let b = try flac(src, "b.flac", title: "Dos", album: "B", cover: makeJPEG(size: 400))
                let error = await syncError { _ = try await pod.session(fault: .duringDBWrite).add([b], progress: { _ in }) }
                expect(error != nil, "se esperaba un error")
                let after = try snapshot(pod.root)
                expect(after == before, "rotate=\(rotate) diferencias: \(Set(after.keys).symmetricDifference(Set(before.keys))) \(before.keys.filter { after[$0] != before[$0] })")
                expect(!after.keys.contains { $0.contains(".tmp-connector") }, "queda temporal")
                expect(!after.keys.contains { $0.hasSuffix("_2.ithmb") }, "queda _2.ithmb")
            }
        },
        TestCase(name: "sync: fallo al guardar en remove conserva el audio y la base") {
            let pod = try makePod()
            let src = try tempDir()
            let report = try await pod.session().add([try flac(src, "a.flac", title: "Uno", cover: makeJPEG(size: 600))], progress: { _ in })
            let track = try require(report.added.first)
            let before = try snapshot(pod.root)
            let error = await syncError { _ = try await pod.session(fault: .duringDBWrite).remove(ids: [track.id]) }
            expect(error != nil, "se esperaba un error")
            expect(try snapshot(pod.root) == before, "el iPod cambió")
            expectEqual(try await pod.session().load().count, 1)
        },
        TestCase(name: "sync: copia a medias (fallo en el 2º de 3) revierte todo") {
            let pod = try makePod()
            let src = try tempDir()
            let urls = try (1...3).map { try flac(src, "t\($0).flac", title: "Pista \($0)", cover: makeJPEG(size: 600), track: $0) }
            let before = try snapshot(pod.root)
            let error = await syncError { _ = try await pod.session(fault: .duringCopy(index: 1)).add(urls, progress: { _ in }) }
            if case .ioFailure = error {} else { expect(false, "esperaba ioFailure, obtuve \(String(describing: error))") }
            expect(try snapshot(pod.root) == before, "el iPod cambió")
        },
        TestCase(name: "sync: guidUnverified no escribe nada") {
            let pod = try makePod()
            try Data("FirewireGuid: 0x1111111111111111\n".utf8).write(to: pod.control.appendingPathComponent("Device/SysInfo"))
            let src = try tempDir()
            let url = try flac(src, "a.flac", title: "Uno")
            let before = try snapshot(pod.root)
            let error = await syncError { _ = try await pod.plainSession().add([url], progress: { _ in }) }
            if case .guidUnverified = error {} else { expect(false, "esperaba guidUnverified, obtuve \(String(describing: error))") }
            expect(try snapshot(pod.root) == before, "el iPod cambió")
            expect(!FileManager.default.fileExists(atPath: pod.backups.path), "no debe haber copias")
        },
        TestCase(name: "sync: borrar sin poder borrar el audio avisa") {
            let pod = try makePod()
            let src = try tempDir()
            let session = pod.session()
            let report = try await session.add([try flac(src, "a.flac", title: "Uno")], progress: { _ in })
            let track = try require(report.added.first)
            let comps = track.location.split(separator: ":").map(String.init)
            let file = pod.root.appendingPathComponent(comps.joined(separator: "/"))
            let dir = file.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            let removal = try await session.remove(ids: [track.id])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            expectEqual(removal.removed, 1)
            expectEqual(removal.warnings.count, 1)
        },
    ]
}
