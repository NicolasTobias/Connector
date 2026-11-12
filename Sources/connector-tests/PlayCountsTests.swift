import Foundation
import ConnectorCore

enum PlayCountsTests {
    static func file(_ entries: [PlayCountEntry], headerLength: Int = 96, entryLength: Int = 16) -> Data {
        var w = ByteWriter()
        w.tag("mhdp"); w.u32(UInt32(headerLength)); w.u32(UInt32(entryLength)); w.u32(UInt32(entries.count))
        w.zeros(headerLength - 16)
        for e in entries {
            let words: [UInt32] = [e.playCount, e.lastPlayed, e.bookmark, e.rating ?? 0, 0, e.skipCount ?? 0]
            for word in words.prefix(entryLength / 4) { w.u32(word) }
        }
        return w.data
    }

    static let all: [TestCase] = [
        TestCase(name: "playcounts: suma reproducciones") {
            let db = ITunesDB.makeEmpty()
            db.add(ITunesDBTests.sample(1))
            db.add(ITunesDBTests.sample(2))
            let root = try Chunk.parse(db.serialize())
            let mhits = try require(ITunesDBTests.sections(root, 1)?.children.first).children
            mhits[0].setU32(3, at: 0x50)
            let base = try ITunesDB(data: root.serialize())
            expectEqual(base.tracks.map(\.playCount), [3, 0])
            let entries = try PlayCounts.parse(file([PlayCountEntry(playCount: 2), PlayCountEntry(playCount: 5)]))
            base.merge(entries)
            expectEqual(try ITunesDB(data: base.serialize()).tracks.map(\.playCount), [5, 5])
        },
        TestCase(name: "playcounts: cabecera inválida") {
            await expectThrows({ _ = try PlayCounts.parse(Data("basura que no es nada".utf8)) }, "sin mhdp")
            await expectThrows({ _ = try PlayCounts.parse(Data()) }, "vacío")
            var short = ByteWriter()
            short.tag("mhdp"); short.u32(8); short.u32(16); short.u32(0); short.zeros(4)
            await expectThrows({ _ = try PlayCounts.parse(short.data) }, "cabecera de 8 bytes")
            await expectThrows({ _ = try PlayCounts.parse(file([], entryLength: 8)) }, "entrada de 8 bytes")
        },
        TestCase(name: "playcounts: más entradas que pistas") {
            let db = ITunesDB.makeEmpty()
            db.add(ITunesDBTests.sample(1))
            db.add(ITunesDBTests.sample(2))
            let entries = try PlayCounts.parse(file([
                PlayCountEntry(playCount: 1), PlayCountEntry(playCount: 2), PlayCountEntry(playCount: 9),
            ]))
            db.merge(entries)
            expectEqual(try ITunesDB(data: db.serialize()).tracks.map(\.playCount), [1, 2])
        },
        TestCase(name: "playcounts: rating y lastPlayed distintos de cero sustituyen") {
            let db = ITunesDB.makeEmpty()
            db.add(ITunesDBTests.sample(1))
            db.merge(try PlayCounts.parse(file([PlayCountEntry(playCount: 0, lastPlayed: 3_600_000_000, rating: 80)])))
            let t = try ITunesDB(data: db.serialize()).tracks[0]
            expectEqual(t.rating, 80)
            expectEqual(t.lastPlayed, Date(timeIntervalSince1970: 3_600_000_000 - 2_082_844_800))

            let keep = ITunesDB.makeEmpty()
            keep.add(ITunesDBTests.sample(1))
            keep.merge(try PlayCounts.parse(file([PlayCountEntry(playCount: 0, lastPlayed: 0, rating: 0)])))
            let k = try ITunesDB(data: keep.serialize()).tracks[0]
            expectEqual(k.rating, 60, "rating 0 no sustituye")
            expect(k.lastPlayed == nil, "lastPlayed 0 no sustituye")
        },
        TestCase(name: "playcounts: entrada truncada lanza error") {
            let data = file([PlayCountEntry(playCount: 1), PlayCountEntry(playCount: 2)])
            await expectThrows({ _ = try PlayCounts.parse(Data(data.dropLast(4))) }, "última entrada cortada")
        },
    ]
}
