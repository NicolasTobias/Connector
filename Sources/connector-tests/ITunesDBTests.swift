import Foundation
import ConnectorCore

enum ITunesDBTests {
    static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map { $0.value } }

    static func sample(_ n: Int, artist: String = "Artista", album: String = "Album") -> NewTrack {
        NewTrack(
            title: "Pista \(n)", artist: artist, album: album, albumArtist: "AA \(n)", genre: "Rock",
            filetype: "MPEG audio file", location: ":iPod_Control:Music:F0\(n):ABC\(n).mp3",
            trackNumber: n, trackCount: 12, discNumber: 1, discCount: 2, year: 1990 + n,
            durationMs: UInt32(180_000 + n), size: UInt32(4_000_000 + n), bitrate: 256, sampleRate: 44100,
            artworkId: nil, rating: 60
        )
    }

    static func sections(_ root: Chunk, _ type: UInt32) -> Chunk? {
        root.children.first { $0.tag == "mhsd" && $0.u32(at: 12) == type }
    }

    static func masterPlaylist(_ root: Chunk, type: UInt32) -> Chunk? {
        sections(root, type)?.children.first { $0.tag == "mhlp" }?.children.first { $0.tag == "mhyp" && $0.header[0x14] == 1 }
    }

    static func mhipIds(_ mhyp: Chunk) -> [UInt32] {
        mhyp.children.filter { $0.tag == "mhip" }.map { $0.u32(at: 24) }
    }

    static func referencedIds(_ root: Chunk) -> Set<UInt32> {
        var ids = Set<UInt32>()
        for type in [2, 3, 5] as [UInt32] {
            for pl in sections(root, type)?.children.first(where: { $0.tag == "mhlp" })?.children ?? [] {
                ids.formUnion(mhipIds(pl))
            }
        }
        return ids
    }

    static func unknownMhod(_ type: UInt32) -> Chunk {
        var w = ByteWriter()
        w.tag("mhod"); w.u32(24); w.u32(0); w.u32(type); w.u32(0); w.u32(0)
        return Chunk(tag: "mhod", header: w.data, payload: Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    static func header(_ tag: String, _ length: Int) -> Chunk {
        var h = Data(count: length)
        h.replaceSubrange(0..<4, with: Data(tag.utf8))
        let c = Chunk(tag: tag, header: h)
        c.setU32(UInt32(length), at: 4)
        return c
    }

    static let all: [TestCase] = [
        TestCase(name: "itdb: base vacía tiene lista maestra") {
            let db = try ITunesDB(data: ITunesDB.makeEmpty().serialize())
            expect(db.tracks.isEmpty)
            let root = try Chunk.parse(db.serialize())
            expect(masterPlaylist(root, type: 2) != nil, "maestra en tipo 2")
            expect(masterPlaylist(root, type: 3) != nil, "maestra en tipo 3")
        },
        TestCase(name: "itdb: rechaza datos que no son iTunesDB") {
            await expectThrows { _ = try ITunesDB(data: Data("basura que no es nada".utf8)) }
        },
        TestCase(name: "itdb: añadir y releer") {
            let db = ITunesDB.makeEmpty()
            let a = sample(1), b = sample(2, artist: "Otro", album: "Otro disco")
            let ta = db.add(a), tb = db.add(b)
            expect(ta.id != tb.id)
            expect(ta.dbid != tb.dbid)
            let reread = try ITunesDB(data: db.serialize())
            expectEqual(reread.tracks.count, 2)
            for (t, n) in zip(reread.tracks, [a, b]) {
                expectEqual(t.title, n.title); expectEqual(t.artist, n.artist); expectEqual(t.album, n.album)
                expectEqual(t.albumArtist, n.albumArtist); expectEqual(t.genre, n.genre)
                expectEqual(t.filetype, n.filetype); expectEqual(t.location, n.location)
                expectEqual(t.trackNumber, n.trackNumber); expectEqual(t.trackCount, n.trackCount)
                expectEqual(t.discNumber, n.discNumber); expectEqual(t.discCount, n.discCount)
                expectEqual(t.year, n.year); expectEqual(t.durationMs, n.durationMs)
                expectEqual(t.size, n.size); expectEqual(t.bitrate, n.bitrate)
                expectEqual(t.sampleRate, n.sampleRate); expectEqual(t.rating, n.rating)
                expectEqual(t.artworkId, n.artworkId)
                expectEqual(t.playCount, 0); expectEqual(t.skipCount, 0); expect(t.lastPlayed == nil)
            }
            expectEqual(reread.tracks.map(\.id), [ta.id, tb.id])
            let root = try Chunk.parse(db.serialize())
            for type in [2, 3] as [UInt32] {
                let m = try require(masterPlaylist(root, type: type))
                expectEqual(mhipIds(m), [ta.id, tb.id], "mhip tipo \(type)")
                expectEqual(m.u32(at: 16), 2)
                expectEqual(m.u32(at: 12), UInt32(m.children.filter { $0.tag == "mhod" }.count))
                expectEqual(m.children.filter { $0.tag == "mhod" && [52, 53].contains($0.u32(at: 12)) }.count, 10)
            }
            let mhlt = try require(sections(root, 1)?.children.first)
            expectEqual(mhlt.u32(at: 8), 2)
            let mhit = mhlt.children[0]
            expectEqual(mhit.u32(at: 4), 0x248)
            expectEqual(mhit.u32(at: 12), UInt32(mhit.children.count))
            expectEqual(mhit.u32(at: 0xD0), 1)
        },
        TestCase(name: "itdb: título con acentos y emoji sobrevive al ciclo") {
            let nfd = "Canción ñandú 🎷".decomposedStringWithCanonicalMapping
            var n = sample(1)
            n.title = nfd
            n.artist = "Beyoncé ✨".decomposedStringWithCanonicalMapping
            let db = ITunesDB.makeEmpty()
            db.add(n)
            let back = try ITunesDB(data: db.serialize()).tracks[0]
            expectEqual(scalars(back.title), scalars(nfd))
            expectEqual(scalars(back.artist), scalars(n.artist))
        },
        TestCase(name: "itdb: borrar quita mhit y mhip") {
            let db = ITunesDB.makeEmpty()
            let t = (1...3).map { db.add(sample($0, artist: "Art \($0)", album: "Alb \($0)")) }
            db.remove(ids: [t[1].id])
            let reread = try ITunesDB(data: db.serialize())
            expectEqual(reread.tracks.map(\.id), [t[0].id, t[2].id])
            let root = try Chunk.parse(db.serialize())
            expect(!referencedIds(root).contains(t[1].id))
            for type in [2, 3] as [UInt32] {
                let m = try require(masterPlaylist(root, type: type))
                expectEqual(mhipIds(m), [t[0].id, t[2].id])
                expectEqual(m.u32(at: 16), 2)
            }
            expectEqual(try require(sections(root, 1)?.children.first).u32(at: 8), 2)
            let albums = try require(sections(root, 4)?.children.first)
            expectEqual(albums.u32(at: 8), 2, "álbumes huérfanos retirados")
            expectEqual(albums.children.count, 2)
            let artists = try require(sections(root, 8)?.children.first)
            expectEqual(artists.u32(at: 8), 2)
        },
        TestCase(name: "itdb: borrar también quita de listas no maestras") {
            let db = ITunesDB.makeEmpty()
            let t = (1...2).map { db.add(sample($0)) }
            let root = try Chunk.parse(db.serialize())
            let list = try require(sections(root, 2)?.children.first)
            let pl = header("mhyp", 108)
            pl.setU32(0, at: 0x14)
            var h = ByteWriter()
            h.tag("mhip"); h.u32(76); h.u32(0); h.u32(1); h.u32(0); h.u32(0); h.u32(t[0].id); h.u32(0); h.u32(0); h.zeros(40)
            pl.children = [unknownMhod(1), Chunk(tag: "mhip", header: h.data)]
            pl.setU32(1, at: 16)
            list.children.append(pl)
            list.setU32(UInt32(list.children.count), at: 8)
            let db2 = try ITunesDB(data: root.serialize())
            db2.remove(ids: [t[0].id])
            let after = try Chunk.parse(db2.serialize())
            expect(!referencedIds(after).contains(t[0].id))
            let pl2 = try require(sections(after, 2)?.children.first?.children.last)
            expectEqual(pl2.u32(at: 16), 0)
            expectEqual(pl2.children.count, 1)
        },
        TestCase(name: "itdb: índice 52 ordenado por artista") {
            let db = ITunesDB.makeEmpty()
            let artists = ["Zappa", "abba", "Beck"]
            for (i, a) in artists.enumerated() { db.add(sample(i + 1, artist: a, album: "Alb")) }
            let root = try Chunk.parse(db.serialize())
            let m = try require(masterPlaylist(root, type: 2))
            let idx = try require(m.children.first { $0.tag == "mhod" && $0.u32(at: 12) == 52 && $0.payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 5 })
            let count = Int(idx.payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
            expectEqual(count, 3)
            let order = (0..<count).map { i in Int(idx.payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48 + 4 * i, as: UInt32.self) }) }
            expectEqual(order.map { artists[$0] }, ["abba", "Beck", "Zappa"])
            expectEqual(idx.u32(at: 8), UInt32(24 + 48 + 4 * count))
            let jump = try require(m.children.first { $0.tag == "mhod" && $0.u32(at: 12) == 53 && $0.payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 5 })
            expectEqual(jump.payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }, 3)
            expectEqual(jump.payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt16.self) }, 0x41)
        },
        TestCase(name: "itdb: lo desconocido se conserva") {
            let seed = try Chunk.parse(ITunesDB.makeEmpty().serialize())
            let six = header("mhsd", 96)
            six.setU32(6, at: 12)
            let six2 = header("mhlt", 92)
            six.children = [six2]
            let five = header("mhsd", 96)
            five.setU32(5, at: 12)
            let fl = header("mhlp", 92)
            let other = header("mhyp", 108)
            other.setU32(0, at: 0x14)
            other.setU32(3, at: 12)
            other.children = [unknownMhod(1), unknownMhod(777), unknownMhod(4242)]
            fl.children = [other]
            fl.setU32(1, at: 8)
            five.children = [fl]
            seed.children.append(contentsOf: [six, five])
            seed.setU32(UInt32(seed.children.count), at: 20)
            try require(sections(seed, 2)?.children.first).children.append(other)
            try require(sections(seed, 2)?.children.first).setU32(2, at: 8)
            let before = seed.serialize()
            let beforeSix = six.serialize(), beforeFive = five.serialize(), beforeOther = other.serialize()

            let db = try ITunesDB(data: before)
            db.add(sample(1))
            db.add(sample(2))
            db.remove(ids: [db.tracks[0].id])
            let after = try Chunk.parse(db.serialize())
            expectEqual(try require(sections(after, 6)).serialize(), beforeSix)
            expectEqual(try require(sections(after, 5)).serialize(), beforeFive)
            let kept = try require(sections(after, 2)?.children.first?.children.last)
            expectEqual(kept.serialize(), beforeOther)
        },
        TestCase(name: "itdb: álbumes y artistas se reutilizan y se enlazan") {
            let db = ITunesDB.makeEmpty()
            var a = sample(1, artist: "Mismo", album: "Disco"); a.albumArtist = ""
            var b = sample(2, artist: "Mismo", album: "Disco"); b.albumArtist = ""
            db.add(a); db.add(b)
            let root = try Chunk.parse(db.serialize())
            let mhits = try require(sections(root, 1)?.children.first).children
            expectEqual(mhits[0].u32(at: 0x120), mhits[1].u32(at: 0x120))
            expect(mhits[0].u32(at: 0x120) != 0)
            expectEqual(mhits[0].u32(at: 0x1E0), mhits[1].u32(at: 0x1E0))
            expectEqual(try require(sections(root, 4)?.children.first).u32(at: 8), 1)
            expectEqual(try require(sections(root, 8)?.children.first).u32(at: 8), 1)
        },
        TestCase(name: "itdb: carátula actualiza los campos de arte") {
            let db = ITunesDB.makeEmpty()
            let t = db.add(sample(1))
            db.setArtwork(trackId: t.id, artworkId: 1234, size: 777)
            let back = try ITunesDB(data: db.serialize()).tracks[0]
            expectEqual(back.artworkId, 1234)
            let mhit = try require(sections(try Chunk.parse(db.serialize()), 1)?.children.first).children[0]
            expectEqual(mhit.u32(at: 0x80), 777)
            expectEqual(mhit.u16(at: 0x7C), 1)
            expectEqual(mhit.header[0xA4], 1)
        },
        TestCase(name: "itdb: cabeceras cortas lanzan error sin abortar") {
            func seeded() throws -> Chunk {
                let db = ITunesDB.makeEmpty()
                db.add(sample(1))
                return try Chunk.parse(db.serialize())
            }
            func shorten(_ c: Chunk) { c.header = Data(c.header.prefix(12)); c.setU32(12, at: 4) }
            let cases: [(String, (Chunk) throws -> Void)] = [
                ("mhsd", { shorten(try require(sections($0, 1))) }),
                ("mhod en mhit", { shorten(try require(sections($0, 1)?.children.first?.children.first?.children.first)) }),
                ("mhia", { shorten(try require(sections($0, 4)?.children.first?.children.first)) }),
                ("mhii", { shorten(try require(sections($0, 8)?.children.first?.children.first)) }),
                ("mhyp", { shorten(try require(masterPlaylist($0, type: 2))) }),
                ("mhip", { shorten(try require(masterPlaylist($0, type: 2)?.children.first { $0.tag == "mhip" })) }),
                ("mhit", { shorten(try require(sections($0, 1)?.children.first?.children.first)) }),
            ]
            for (name, mutate) in cases {
                let root = try seeded()
                try mutate(root)
                let data = root.serialize()
                await expectThrows({ _ = try ITunesDB(data: data) }, name)
            }
            let full = try seeded().serialize()
            let mhltStart = 244 + 96
            for cut in [mhltStart + 10, mhltStart + 92 + 30, full.count / 2, full.count - 1, 8, 0] {
                let part = full.prefix(cut)
                await expectThrows({ _ = try ITunesDB(data: Data(part)) }, "corte en \(cut)")
            }
        },
        TestCase(name: "itdb: nombre del iPod real sale de la lista maestra") {
            let path = try skipUnless("CONNECTOR_REAL_IPOD_CONTROL")[0]
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("iTunes/iTunesDB"))
            let name = try ITunesDB(data: data).deviceName
            expect(name?.isEmpty == false, "nombre: \(String(describing: name))")
        },
        TestCase(name: "itdb: una base vacía se llama iPod por defecto") {
            expectEqual(ITunesDB.makeEmpty().deviceName, "iPod")
        },
        TestCase(name: "itdb: base real, añadir y borrar vuelve al original semántico") {
            let path = try skipUnless("CONNECTOR_REAL_IPOD_CONTROL")[0]
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("iTunes/iTunesDB"))
            let original = try Chunk.parse(data)
            let db = try ITunesDB(data: data)
            let tracksBefore = db.tracks
            let added = db.add(sample(1))
            db.remove(ids: [added.id])
            expectEqual(db.tracks, tracksBefore)
            let after = try Chunk.parse(db.serialize())
            for type in 1...12 as ClosedRange<UInt32> where ![2, 3, 4, 8].contains(type) {
                expectEqual(sections(after, type)?.serialize(), sections(original, type)?.serialize(), "mhsd \(type)")
            }
            for type in [2, 3] as [UInt32] {
                let o = sections(original, type)?.children.first?.children ?? []
                let n = sections(after, type)?.children.first?.children ?? []
                expectEqual(o.count, n.count)
                for (x, y) in zip(o, n) where x.header[0x14] != 1 {
                    expectEqual(x.serialize(), y.serialize(), "playlist no maestra")
                }
            }
        },
    ]
}

struct MissingValue: Error {}

@discardableResult
func require<T>(_ v: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let v else { throw MissingValue() }
    return v
}
