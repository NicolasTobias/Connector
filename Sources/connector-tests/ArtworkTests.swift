import CoreGraphics
import Foundation
import ConnectorCore

enum ArtworkTests {
    static func solid(red: UInt8, green: UInt8, blue: UInt8, width: Int = 10, height: Int = 10) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func imageList(_ root: Chunk) -> Chunk? {
        root.children.first { $0.tag == "mhsd" && $0.u16(at: 12) == 1 }?.children.first { $0.tag == "mhli" }
    }

    static func thumbChunks(_ mhii: Chunk) throws -> [Chunk] {
        try mhii.children.filter { $0.tag == "mhod" && $0.u16(at: 12) == 2 }.map { try Chunk.parse($0.payload) }
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil) ?? -1
    }

    static let formatIds: [UInt32] = [1061, 1055, 1068, 1060]
    static let expectedGrowth = [56 * 56 * 2, 128 * 128 * 2, 128 * 128 * 2, 320 * 320 * 2]

    static let all: [TestCase] = [
        TestCase(name: "artwork: rgb565 de un rojo puro") {
            let data = ArtworkRenderer.rgb565LE(solid(red: 255, green: 0, blue: 0), side: 56)
            expectEqual(data.count, 56 * 56 * 2)
            let centre = (28 * 56 + 28) * 2
            expectEqual(data[centre], 0x00)
            expectEqual(data[centre + 1], 0xF8)
            let letterbox = ArtworkRenderer.rgb565LE(solid(red: 255, green: 255, blue: 255, width: 20, height: 10), side: 40)
            expectEqual(letterbox.count, 40 * 40 * 2)
            expectEqual(letterbox[0], 0)
            expectEqual(letterbox[1], 0)
            let mid = (20 * 40 + 20) * 2
            expectEqual(letterbox[mid], 0xFF)
            expectEqual(letterbox[mid + 1], 0xFF)
        },
        TestCase(name: "artwork: añadir crea 4 formatos") {
            let dir = try tempDir()
            let db = ArtworkDB.makeEmpty()
            let result = try db.add(cover: solid(red: 10, green: 200, blue: 30), sourceByteCount: 1234, songDbId: 42, artworkDir: dir)
            expectEqual(result.imageId, 100)
            expectEqual(result.sourceSize, 1234)
            let root = try Chunk.parse(db.serialize())
            let list = imageList(root)
            expectEqual(list?.u32(at: 8) ?? 0, 1)
            let mhii = list?.children.first
            expectEqual(mhii?.tag ?? "", "mhii")
            expectEqual(mhii?.u32(at: 16) ?? 0, 100)
            let thumbs = try mhii.map(thumbChunks) ?? []
            expectEqual(thumbs.map { $0.u32(at: 16) }, formatIds)
            for (i, mhni) in thumbs.enumerated() {
                expectEqual(mhni.tag, "mhni")
                expectEqual(mhni.u32(at: 20), 0)
                expectEqual(Int(mhni.u32(at: 24)), expectedGrowth[i])
                let side = Int(mhni.u16(at: 32))
                expectEqual(Int(mhni.u16(at: 34)), side)
                expectEqual(side * side * 2, expectedGrowth[i])
                let name = mhni.children.first
                expectEqual(name?.tag ?? "", "mhod")
                expectEqual(name?.u16(at: 12) ?? 0, 3)
                let expectedName = ":F\(formatIds[i])_1.ithmb"
                expectEqual(String(data: name?.payload.dropFirst(12) ?? Data(), encoding: .utf16LittleEndian)?.trimmingCharacters(in: .controlCharacters) ?? "", expectedName)
                expectEqual(fileSize(dir.appendingPathComponent("F\(formatIds[i])_1.ithmb")), expectedGrowth[i])
            }
            let second = try db.add(cover: solid(red: 0, green: 0, blue: 255), sourceByteCount: 1234, songDbId: 42, artworkDir: dir)
            expectEqual(second.imageId, 101)
            let again = try Chunk.parse(db.serialize())
            let offsets = try imageList(again)?.children.last.map(thumbChunks)?.map { Int($0.u32(at: 20)) } ?? []
            expectEqual(offsets, expectedGrowth)
            for (i, id) in formatIds.enumerated() {
                expectEqual(fileSize(dir.appendingPathComponent("F\(id)_1.ithmb")), expectedGrowth[i] * 2)
            }
            let formats = again.children.first { $0.tag == "mhsd" && $0.u16(at: 12) == 3 }?.children.first?.children.map { $0.u32(at: 16) }
            expectEqual(formats ?? [], formatIds)
            _ = try ArtworkDB(data: db.serialize())
        },
        TestCase(name: "artwork: ciclo con ArtworkDB real") {
            let path = try skipUnless("CONNECTOR_REAL_IPOD_CONTROL")[0]
            let url = URL(fileURLWithPath: path).appendingPathComponent("Artwork/ArtworkDB")
            let original = try Data(contentsOf: url)
            let db = try ArtworkDB(data: original)
            expectEqual(db.serialize(), original)
            let dir = try tempDir()
            let before = try Chunk.parse(original)
            let added = try db.add(cover: solid(red: 1, green: 2, blue: 3), sourceByteCount: 1234, songDbId: 42, artworkDir: dir)
            db.remove(imageIds: [added.imageId])
            let after = try Chunk.parse(db.serialize())
            expectEqual(
                imageList(after)?.children.map { $0.serialize() } ?? [],
                imageList(before)?.children.map { $0.serialize() } ?? []
            )
            for index in [1, 2] as [UInt16] {
                let pick: (Chunk) -> Data? = { $0.children.first { $0.tag == "mhsd" && $0.u16(at: 12) == index }?.serialize() }
                expectEqual(pick(after), pick(before))
            }
        },
        TestCase(name: "artwork: song_id y orig_img_size se escriben") {
            let db = ArtworkDB.makeEmpty()
            let r = try db.add(cover: solid(red: 1, green: 2, blue: 3), sourceByteCount: 98765, songDbId: 0x1122_3344_5566_7788, artworkDir: try tempDir())
            expectEqual(r.sourceSize, 98765)
            let mhii = imageList(try Chunk.parse(db.serialize()))?.children.first
            expectEqual(mhii?.u64(at: 20) ?? 0, 0x1122_3344_5566_7788)
            expectEqual(mhii?.u32(at: 48) ?? 0, 98765)
        },
        TestCase(name: "artwork: rota a _2 al llegar a 256 MB") {
            let dir = try tempDir()
            let big = dir.appendingPathComponent("F1055_1.ithmb")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let h = try FileHandle(forWritingTo: big)
            try h.truncate(atOffset: 256_000_000)
            try h.close()
            let db = ArtworkDB.makeEmpty()
            _ = try db.add(cover: solid(red: 1, green: 2, blue: 3), sourceByteCount: 10, songDbId: 1, artworkDir: dir)
            expectEqual(fileSize(dir.appendingPathComponent("F1055_2.ithmb")), 128 * 128 * 2)
            expectEqual(fileSize(big), 256_000_000)
            let mhii = imageList(try Chunk.parse(db.serialize()))?.children.first
            let mhni = try mhii.map(thumbChunks)?[1]
            expectEqual(mhni?.u32(at: 16) ?? 0, 1055)
            expectEqual(mhni?.u32(at: 20) ?? 1, 0)
            let name = mhni?.children.first
            expectEqual(String(data: name?.payload.dropFirst(12) ?? Data(), encoding: .utf16LittleEndian)?.trimmingCharacters(in: .controlCharacters) ?? "", ":F1055_2.ithmb")
        },
        TestCase(name: "artwork: remove quita el mhii") {
            let dir = try tempDir()
            let db = ArtworkDB.makeEmpty()
            let a = try db.add(cover: solid(red: 255, green: 0, blue: 0), sourceByteCount: 1234, songDbId: 42, artworkDir: dir)
            let b = try db.add(cover: solid(red: 0, green: 255, blue: 0), sourceByteCount: 1234, songDbId: 42, artworkDir: dir)
            db.remove(imageIds: [a.imageId])
            let root = try Chunk.parse(db.serialize())
            let list = imageList(root)
            expectEqual(list?.u32(at: 8) ?? 0, 1)
            expectEqual(list?.children.map { $0.u32(at: 16) } ?? [], [b.imageId])
            expectEqual(fileSize(dir.appendingPathComponent("F1061_1.ithmb")), 56 * 56 * 2 * 2)
            db.remove(imageIds: [b.imageId])
            expectEqual(imageList(try Chunk.parse(db.serialize()))?.children.count ?? -1, 0)
        },
        TestCase(name: "artwork: sobre una base existente conserva los mhii previos") {
            let dir = try tempDir()
            let first = ArtworkDB.makeEmpty()
            _ = try first.add(cover: solid(red: 255, green: 0, blue: 0), sourceByteCount: 1234, songDbId: 42, artworkDir: dir)
            let saved = first.serialize()
            let db = try ArtworkDB(data: saved)
            expectEqual(db.serialize(), saved)
            let added = try db.add(cover: solid(red: 0, green: 0, blue: 255), sourceByteCount: 1234, songDbId: 42, artworkDir: dir)
            expectEqual(added.imageId, 101)
            let old = try Chunk.parse(saved)
            let new = try Chunk.parse(db.serialize())
            expectEqual(imageList(new)?.u32(at: 8) ?? 0, 2)
            expectEqual(imageList(new)?.children.first?.serialize(), imageList(old)?.children.first?.serialize())
            let offsets = try imageList(new)?.children.last.map(thumbChunks)?.map { Int($0.u32(at: 20)) } ?? []
            expectEqual(offsets, expectedGrowth)
        },
        TestCase(name: "artwork: cabeceras cortas lanzan error") {
            let good = ArtworkDB.makeEmpty().serialize()
            await expectThrows({ _ = try ArtworkDB(data: Data()) })
            await expectThrows({ _ = try ArtworkDB(data: good.prefix(good.count - 5)) })
            await expectThrows({ _ = try ArtworkDB(data: Data("mhbd".utf8) + Data(count: 100)) })
            let root = try Chunk.parse(good)
            let mhsd = root.children[0]
            mhsd.header = mhsd.header.prefix(14)
            mhsd.setU32(14, at: 4)
            await expectThrows({ _ = try ArtworkDB(data: root.serialize()) }, "mhsd corto")
            let list = try Chunk.parse(good)
            list.children[0].children[0].header = Data(list.children[0].children[0].header.prefix(12))
            list.children[0].children[0].setU32(12, at: 4)
            _ = try ArtworkDB(data: list.serialize())
            let noList = try Chunk.parse(good)
            noList.children.removeFirst()
            await expectThrows({ _ = try ArtworkDB(data: noList.serialize()) }, "sin mhli")
        },
        TestCase(name: "artwork: fallo al añadir revierte los ithmb") {
            let dir = try tempDir()
            let db = ArtworkDB.makeEmpty()
            _ = try db.add(cover: solid(red: 255, green: 0, blue: 0), sourceByteCount: 1234, songDbId: 42, artworkDir: dir)
            let before = db.serialize()
            let sizes = formatIds.map { fileSize(dir.appendingPathComponent("F\($0)_1.ithmb")) }
            let blocked = try tempDir()
            try FileManager.default.createDirectory(at: blocked.appendingPathComponent("F1055_1.ithmb"), withIntermediateDirectories: true)
            let fresh = ArtworkDB.makeEmpty()
            await expectThrows({ _ = try fresh.add(cover: solid(red: 0, green: 255, blue: 0), sourceByteCount: 1234, songDbId: 42, artworkDir: blocked) })
            expectEqual(fileSize(blocked.appendingPathComponent("F1061_1.ithmb")), -1, "fichero nuevo eliminado")
            expectEqual(imageList(try Chunk.parse(fresh.serialize()))?.children.count ?? -1, 0)
            let existing = try tempDir()
            let seed = Data(repeating: 7, count: 100)
            try seed.write(to: existing.appendingPathComponent("F1061_1.ithmb"))
            try FileManager.default.createDirectory(at: existing.appendingPathComponent("F1055_1.ithmb"), withIntermediateDirectories: true)
            await expectThrows({ _ = try ArtworkDB.makeEmpty().add(cover: solid(red: 0, green: 255, blue: 0), sourceByteCount: 1234, songDbId: 42, artworkDir: existing) })
            expectEqual(try Data(contentsOf: existing.appendingPathComponent("F1061_1.ithmb")), seed, "truncado al tamaño previo")
            expectEqual(db.serialize(), before)
            expectEqual(formatIds.map { fileSize(dir.appendingPathComponent("F\($0)_1.ithmb")) }, sizes)
        },
    ]
}
