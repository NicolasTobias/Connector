import Foundation
import ConnectorCore

enum ChunkTests {
    static func mhod(_ body: Int) -> Data {
        var w = ByteWriter()
        w.tag("mhod"); w.u32(24); w.u32(UInt32(24 + body)); w.u32(1); w.u32(0); w.u32(0)
        w.bytes(Data((0..<body).map { UInt8($0 & 0xFF) }))
        return w.data
    }

    static func mhit(_ id: UInt32, mhods: [Data]) -> Data {
        var w = ByteWriter()
        let hl = 32
        let total = hl + mhods.reduce(0) { $0 + $1.count }
        w.tag("mhit"); w.u32(UInt32(hl)); w.u32(UInt32(total)); w.u32(UInt32(mhods.count))
        w.u32(id); w.zeros(12)
        for m in mhods { w.bytes(m) }
        return w.data
    }

    static func sample() -> Data {
        let items = [mhit(1, mhods: [mhod(8), mhod(12)]), mhit(2, mhods: [mhod(4), mhod(16)])]
        var lt = ByteWriter()
        lt.tag("mhlt"); lt.u32(92); lt.u32(2); lt.zeros(80)
        for i in items { lt.bytes(i) }
        var sd = ByteWriter()
        sd.tag("mhsd"); sd.u32(96); sd.u32(UInt32(96 + lt.count)); sd.u32(1); sd.zeros(80)
        sd.bytes(lt.data)
        var bd = ByteWriter()
        bd.tag("mhbd"); bd.u32(104); bd.u32(UInt32(104 + sd.count)); bd.zeros(92)
        bd.bytes(sd.data)
        return bd.data
    }

    static let all: [TestCase] = [
        TestCase(name: "chunk: ciclo byte a byte") {
            let original = sample()
            let root = try Chunk.parse(original)
            expectEqual(root.tag, "mhbd")
            expectEqual(root.children.count, 1)
            let lt = root.children[0].children[0]
            expectEqual(lt.tag, "mhlt")
            expectEqual(lt.children.count, 2)
            expectEqual(lt.children[0].children.count, 2)
            expectEqual(lt.children[0].children[0].payload.count, 8)
            expect(root.serialize() == original, "la serialización difiere del original")
        },
        TestCase(name: "chunk: longitudes recalculadas") {
            let original = sample()
            let root = try Chunk.parse(original)
            let sd = root.children[0]
            let lt = sd.children[0]
            let item = lt.children[0]
            let before = (root.u32(at: 8), sd.u32(at: 8), item.u32(at: 8), lt.u32(at: 8))
            let extra = try Chunk.parse(mhod(20))
            item.children.append(extra)
            let out = try Chunk.parse(root.serialize())
            let osd = out.children[0]
            let olt = osd.children[0]
            let size = UInt32(extra.serialize().count)
            expectEqual(out.u32(at: 8), before.0 + size)
            expectEqual(osd.u32(at: 8), before.1 + size)
            expectEqual(olt.children[0].u32(at: 8), before.2 + size)
            expectEqual(olt.u32(at: 8), before.3)
            expectEqual(UInt32(root.serialize().count), before.0 + size)
        },
        TestCase(name: "chunk: truncado lanza error") {
            let data = sample()
            let cut = data.prefix(data.count - 3)
            do {
                _ = try Chunk.parse(Data(cut))
                expect(false, "se esperaba ChunkError.truncated")
            } catch let e as ChunkError {
                if case .truncated = e {} else { expect(false, "error inesperado \(e)") }
            }
        },
        TestCase(name: "chunk: etiqueta inválida") {
            var d = sample()
            d[0] = 0x00
            do {
                _ = try Chunk.parse(d)
                expect(false, "se esperaba ChunkError.badTag")
            } catch let e as ChunkError {
                if case .badTag = e {} else { expect(false, "error inesperado \(e)") }
            }
        },
        TestCase(name: "chunk: lectura y escritura de enteros") {
            var w = ByteWriter()
            w.u8(1); w.u16(0x0302); w.u32(0x07060504); w.u64(0x0F0E0D0C0B0A0908)
            expectEqual(Array(w.data), Array(1...15).map { UInt8($0) })
            var r = ByteReader(w.data)
            expectEqual(try r.u8(), 1)
            expectEqual(try r.u16(), 0x0302)
            expectEqual(try r.u32(), 0x07060504)
            expectEqual(try r.u64(), 0x0F0E0D0C0B0A0908)
            expectEqual(r.remaining, 0)
            await expectThrows { _ = try r.u8() }
            let c = try Chunk.parse(mhod(4))
            c.setU16(0xBEEF, at: 12); c.setU32(0xCAFEBABE, at: 16)
            expectEqual(c.u16(at: 12), 0xBEEF)
            expectEqual(c.u32(at: 16), 0xCAFEBABE)
            c.setU64(0x1122334455667788, at: 12)
            expectEqual(c.u64(at: 12), 0x1122334455667788)
        },
        TestCase(name: "chunk: ciclo con iTunesDB real") {
            let root = try skipUnless("CONNECTOR_REAL_IPOD_CONTROL")[0]
            for rel in ["iTunes/iTunesDB", "Artwork/ArtworkDB"] {
                let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let data = try Data(contentsOf: url)
                let out = try Chunk.parse(data).serialize()
                expect(out == data, "ciclo no idéntico en \(rel)")
            }
        },
    ]
}
