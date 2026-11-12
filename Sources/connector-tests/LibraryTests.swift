import Foundation
import ConnectorCore

enum LibraryTests {
    static func track(_ id: UInt32, _ title: String, album: String, artist: String = "AURORA", albumArtist: String = "", n: Int = 0, disc: Int = 0, added: UInt32 = 0) -> Track {
        Track(id: id, title: title, artist: artist, album: album, albumArtist: albumArtist, trackNumber: n, discNumber: disc, durationMs: 60_000, timeAdded: added)
    }

    static let sample: [Track] = [
        track(1, "B-side", album: "Zeta", n: 2, added: 100),
        track(2, "A-side", album: "Zeta", n: 1, added: 100),
        track(3, "Uno", album: "Álamo", artist: "Otros", n: 1, added: 300),
        track(4, "Solo", album: "beta", n: 1, added: 200),
        track(5, "Suelta", album: "", artist: "Nadie", n: 0, added: 50),
    ]

    static let all: [TestCase] = [
        TestCase(name: "library: agrupa por álbum y artista del álbum, pistas por número") {
            let groups = Library.groups(from: sample)
            expectEqual(groups.count, 4)
            let zeta = groups.first { $0.album == "Zeta" }
            expectEqual(zeta?.tracks.map(\.title) ?? [], ["A-side", "B-side"])
            expectEqual(zeta?.durationMs ?? 0, 120_000)
        },
        TestCase(name: "library: un recopilatorio con distintos artistas es un solo álbum") {
            let mixed = [
                track(1, "x", album: "Compi", artist: "A", albumArtist: "Varios", n: 1),
                track(2, "y", album: "Compi", artist: "B", albumArtist: "Varios", n: 2),
            ]
            let groups = Library.groups(from: mixed)
            expectEqual(groups.count, 1)
            expectEqual(groups[0].artist, "Varios")
        },
        TestCase(name: "library: discos ordenan antes que el número de pista") {
            let two = [
                track(1, "d2t1", album: "Doble", n: 1, disc: 2),
                track(2, "d1t2", album: "Doble", n: 2, disc: 1),
                track(3, "d1t1", album: "Doble", n: 1, disc: 1),
            ]
            expectEqual(Library.groups(from: two)[0].tracks.map(\.title), ["d1t1", "d1t2", "d2t1"])
        },
        TestCase(name: "library: orden alfabético sin mayúsculas ni acentos y sin álbum al final") {
            let sorted = Library.sorted(Library.groups(from: sample), by: .album)
            expectEqual(sorted.map(\.album), ["Álamo", "beta", "Zeta", "Unknown Album"])
        },
        TestCase(name: "library: último agregado primero, y a igual fecha el id mayor") {
            let sorted = Library.sorted(Library.groups(from: sample), by: .recent)
            expectEqual(sorted.map(\.album), ["Álamo", "beta", "Zeta", "Unknown Album"])
            let tie = [track(1, "a", album: "Viejo", added: 10), track(9, "b", album: "Nuevo", added: 10)]
            expectEqual(Library.sorted(Library.groups(from: tie), by: .recent).map(\.album), ["Nuevo", "Viejo"])
        },
        TestCase(name: "library: por defecto todo está desplegado y se puede plegar un álbum") {
            let groups = Library.sorted(Library.groups(from: sample), by: .album)
            expectEqual(Library.rows(groups: groups, collapsed: []).count, groups.count + sample.count)
            let rows = Library.rows(groups: groups, collapsed: [groups[2].id])
            expectEqual(rows.count, groups.count + sample.count - 2)
            if case .album(let g, let open) = rows[4] { expectEqual(g.album, "Zeta"); expect(!open) } else { expect(false, "se esperaba un álbum") }
        },
        TestCase(name: "library: las pistas salen debajo de su álbum, sin mezclarse") {
            let groups = Library.sorted(Library.groups(from: sample), by: .album)
            let rows = Library.rows(groups: groups, collapsed: [])
            if case .album(let g, _) = rows[0] { expectEqual(g.album, "Álamo") } else { expect(false, "fila 0") }
            if case .track(let t, _) = rows[1] { expectEqual(t.title, "Uno") } else { expect(false, "fila 1") }
            if case .album(let g, _) = rows[2] { expectEqual(g.album, "beta") } else { expect(false, "fila 2") }
        },
        TestCase(name: "appmodel: seleccionar un álbum selecciona todas sus pistas") {
            await MainActor.run {
                let m = AppModel(volumesRoot: URL(fileURLWithPath: "/nonexistent"))
                m.setPreview(device: IPodDevice(volume: URL(fileURLWithPath: "/Volumes/x"), name: "x", modelNumber: nil, capacityBytes: 1000, freeBytes: 500), tracks: sample)
                let zeta = m.albums.first { $0.album == "Zeta" }!
                m.clickAlbum(zeta.id, command: false)
                expectEqual(m.selection, [1, 2])
                m.clickAlbum(zeta.id, command: true)
                expectEqual(m.selection, [])
                expect(!m.canRemove)
            }
        },
        TestCase(name: "appmodel: el rango con mayúsculas usa solo las pistas visibles") {
            await MainActor.run {
                let m = AppModel(volumesRoot: URL(fileURLWithPath: "/nonexistent"))
                m.setPreview(device: IPodDevice(volume: URL(fileURLWithPath: "/Volumes/x"), name: "x", modelNumber: nil, capacityBytes: 1000, freeBytes: 500), tracks: sample)
                let zeta = m.albums.first { $0.album == "Zeta" }!
                m.clickTrack(2, shift: false, command: false)
                m.clickTrack(1, shift: true, command: false)
                expectEqual(m.selection, [1, 2])
                m.setSort(.recent)
                expectEqual(m.albums.first?.album ?? "", "Álamo")
                m.collapseAll()
                expectEqual(m.rows.count, m.albums.count)
                m.expandAll()
                expectEqual(m.rows.count, m.albums.count + m.tracks.count)
                _ = zeta
            }
        },
    ]
}
