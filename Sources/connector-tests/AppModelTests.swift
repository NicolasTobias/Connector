import Foundation
import ConnectorCore

enum AppModelTests {
    @MainActor
    static func model(for pod: SyncTests.Pod) -> AppModel {
        AppModel(volumesRoot: pod.root.deletingLastPathComponent(), backupsRoot: pod.backups, guidOverride: SyncTests.guid)
    }

    static let all: [TestCase] = [
        TestCase(name: "appmodel: el nombre mostrado es el del iPod y, sin él, el del volumen") {
            await MainActor.run {
                let m = AppModel(volumesRoot: URL(fileURLWithPath: "/nonexistent"))
                let device = IPodDevice(volume: URL(fileURLWithPath: "/Volumes/iPod"), name: "iPod", modelNumber: nil, capacityBytes: 1000, freeBytes: 500)
                m.setPreview(device: device, tracks: [], deviceName: "My iPod")
                expectEqual(m.displayName, "My iPod")
                m.setPreview(device: device, tracks: [])
                expectEqual(m.displayName, "iPod")
            }
        },
        TestCase(name: "appmodel: sin iPod deshabilita acciones") {
            let empty = try tempDir()
            await MainActor.run {
                let m = AppModel(volumesRoot: empty, backupsRoot: empty.appendingPathComponent("b"))
                m.refreshDevice()
                expect(m.device == nil)
                expect(!m.canAdd)
                expect(!m.canRemove)
                expect(!m.canEject)
            }
        },
        TestCase(name: "appmodel: tras añadir refresca la lista") {
            let pod = try SyncTests.makePod()
            let src = try tempDir().appendingPathComponent("a.wav")
            try makeWAV(at: src, seconds: 1, rate: 44100, bits: 16)
            let m = await MainActor.run { model(for: pod) }
            await MainActor.run { m.refreshDevice() }
            await m.reloadTracks()
            await m.add([src])
            await MainActor.run {
                expectEqual(m.tracks.count, 1)
                expect(m.progress == nil)
                expect(!m.busy)
                expect(m.error == nil, m.error ?? "")
                expectEqual(m.lastReport?.added.count ?? 0, 1)
                expect(m.reportText?.contains("Added: 1") == true)
            }
        },
        TestCase(name: "appmodel: borrar sin selección no hace nada") {
            let pod = try SyncTests.makePod()
            let before = try Data(contentsOf: pod.dbURL)
            let m = await MainActor.run { model(for: pod) }
            await MainActor.run { m.refreshDevice() }
            await m.reloadTracks()
            await MainActor.run { expect(!m.canRemove) }
            await m.removeSelected()
            expectEqual(try Data(contentsOf: pod.dbURL), before)
            await MainActor.run { expect(m.lastReport == nil) }
        },
        TestCase(name: "appmodel: el registro lista lo que se añadió") {
            let pod = try SyncTests.makePod()
            let src = try tempDir().appendingPathComponent("a.wav")
            try makeWAV(at: src, seconds: 1, rate: 44100, bits: 16)
            let m = await MainActor.run { model(for: pod) }
            await MainActor.run { m.refreshDevice() }
            await m.reloadTracks()
            await m.add([src])
            await MainActor.run {
                let texts = m.log.map(\.text)
                expect(texts.first?.hasPrefix("Adding 1 item") == true, "inicio: \(texts)")
                expect(texts.contains { $0.hasPrefix("Converting 1/1: a.wav") }, "convirtiendo: \(texts)")
                expect(texts.contains { $0.hasPrefix("Copying 1/1: a.m4a") }, "copiando: \(texts)")
                expect(m.log.contains { $0.kind == .ok && $0.text.hasPrefix("Added:") }, "añadida: \(texts)")
                expect(texts.last?.contains("Added: 1") == true, "final: \(texts)")
                expect(m.logText.contains("Added:"))
            }
        },
        TestCase(name: "appmodel: un arrastre durante otro lote queda en cola") {
            let pod = try SyncTests.makePod()
            let dir = try tempDir()
            let a = dir.appendingPathComponent("a.wav"), b = dir.appendingPathComponent("b.wav")
            try makeWAV(at: a, seconds: 1, rate: 44100, bits: 16)
            try makeWAV(at: b, seconds: 1, rate: 44100, bits: 16)
            let m = await MainActor.run { model(for: pod) }
            await MainActor.run { m.refreshDevice() }
            await m.reloadTracks()
            async let first: Void = m.add([a])
            async let second: Void = m.add([b])
            _ = await (first, second)
            await MainActor.run {
                expectEqual(m.tracks.count, 2, "pistas: \(m.tracks.map(\.title))")
                expectEqual(m.queued, 0)
                expect(!m.busy)
            }
        },
        TestCase(name: "appmodel: un lote nuevo reemplaza el registro") {
            let pod = try SyncTests.makePod()
            let src = try tempDir().appendingPathComponent("a.wav")
            try makeWAV(at: src, seconds: 1, rate: 44100, bits: 16)
            let m = await MainActor.run { model(for: pod) }
            await MainActor.run { m.refreshDevice() }
            await m.reloadTracks()
            await m.add([src])
            await m.add([src])
            await MainActor.run {
                expect(!m.log.contains { $0.text.hasPrefix("Added:") }, "sigue el lote anterior: \(m.log.map(\.text))")
                expect(m.log.contains { $0.kind == .skip && $0.text.hasPrefix("Duplicate") }, "duplicada: \(m.log.map(\.text))")
            }
        },
        TestCase(name: "appmodel: un fichero ilegible queda como error en el registro") {
            let pod = try SyncTests.makePod()
            let bad = try tempDir().appendingPathComponent("bad.wav")
            try Data(repeating: 1, count: 10).write(to: bad)
            let m = await MainActor.run { model(for: pod) }
            await MainActor.run { m.refreshDevice() }
            await m.reloadTracks()
            await m.add([bad])
            await MainActor.run {
                expect(m.log.contains { $0.kind == .error && $0.text.hasPrefix("Failed: bad.wav") }, "fallida: \(m.log.map(\.text))")
            }
        },
        TestCase(name: "appmodel: borrar deja las canciones en el registro") {
            let pod = try SyncTests.makePod()
            let src = try tempDir().appendingPathComponent("a.wav")
            try makeWAV(at: src, seconds: 1, rate: 44100, bits: 16)
            let m = await MainActor.run { model(for: pod) }
            await MainActor.run { m.refreshDevice() }
            await m.reloadTracks()
            await m.add([src])
            await MainActor.run { m.selection = Set(m.tracks.map(\.id)) }
            await m.removeSelected()
            await MainActor.run {
                expect(m.log.first?.text.hasPrefix("Deleting 1 song") == true, "inicio: \(m.log.map(\.text))")
                expect(m.log.contains { $0.kind == .ok && $0.text.hasPrefix("Deleted:") }, "borrada: \(m.log.map(\.text))")
            }
        },
        TestCase(name: "appmodel: borrar la selección quita la pista") {
            let pod = try SyncTests.makePod()
            let src = try tempDir().appendingPathComponent("a.wav")
            try makeWAV(at: src, seconds: 1, rate: 44100, bits: 16)
            let m = await MainActor.run { model(for: pod) }
            await MainActor.run { m.refreshDevice() }
            await m.reloadTracks()
            await m.add([src])
            await MainActor.run { m.selection = Set(m.tracks.map(\.id)) }
            await m.removeSelected()
            await MainActor.run {
                expectEqual(m.tracks.count, 0)
                expectEqual(m.lastReport?.removed ?? 0, 1)
            }
        },
    ]
}
