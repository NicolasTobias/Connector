import Foundation
import ConnectorCore

enum Hash58Tests {
    static let guid: [UInt8] = [0x00, 0x0A, 0x27, 0x00, 0x12, 0x34, 0xAB, 0xCD]

    static func fixture() -> Data {
        var d = Data((0..<0xF4).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
        d.replaceSubrange(0..<4, with: Array("mhbd".utf8))
        return d
    }

    static let all: [TestCase] = [
        TestCase(name: "hash58: firmar y verificar") {
            var d = fixture()
            try Hash58.sign(&d, guid: guid)
            expect(Hash58.verify(d, guid: guid))
            expectEqual(d[0x30], 1)
            expectEqual(d[0x31], 0)
        },
        TestCase(name: "hash58: un byte cambiado invalida") {
            var d = fixture()
            d.append(contentsOf: [UInt8](repeating: 0x55, count: 0x200))
            try Hash58.sign(&d, guid: guid)
            expect(Hash58.verify(d, guid: guid))
            d[0x200] ^= 0xFF
            expect(!Hash58.verify(d, guid: guid))
        },
        TestCase(name: "hash58: GUID distinto invalida") {
            var d = fixture()
            try Hash58.sign(&d, guid: guid)
            var other = guid
            other[7] = 0xCE
            expect(!Hash58.verify(d, guid: other))
        },
        TestCase(name: "hash58: conserva db_id y unk_0x32") {
            var d = fixture()
            let dbId = d.subdata(in: 0x18..<0x20)
            let unk = d.subdata(in: 0x32..<0x46)
            try Hash58.sign(&d, guid: guid)
            expectEqual(d.subdata(in: 0x18..<0x20), dbId)
            expectEqual(d.subdata(in: 0x32..<0x46), unk)
        },
        TestCase(name: "hash58: vector conocido contra libgpod") {
            var d = fixture()
            try Hash58.sign(&d, guid: guid)
            let expected: [UInt8] = [
                0xD3, 0xA1, 0x7C, 0x32, 0x56, 0x29, 0x55, 0xB2, 0xF2, 0xA4,
                0x5B, 0x30, 0xDD, 0x14, 0xD9, 0x29, 0x3C, 0x12, 0x07, 0x7A,
            ]
            expectEqual([UInt8](d.subdata(in: 0x58..<0x6C)), expected)
        },
        TestCase(name: "hash58: rechaza datos inválidos") {
            var short = Data("mhbd".utf8) + Data(count: 10)
            await expectThrows { try Hash58.sign(&short, guid: guid) }
            var bad = Data(count: 0xF4)
            await expectThrows { try Hash58.sign(&bad, guid: guid) }
            var d = fixture()
            await expectThrows { try Hash58.sign(&d, guid: [1, 2, 3]) }
            expect(!Hash58.verify(Data(count: 10), guid: guid))
        },
        TestCase(name: "hash58: parseGUID") {
            expectEqual(Hash58.parseGUID("000A27001234ABCD"), guid)
            expectEqual(Hash58.parseGUID("0x000a27001234abcd"), guid)
            expect(Hash58.parseGUID("000A2700") == nil)
            expect(Hash58.parseGUID("zz0A27001234ABCD") == nil)
        },
        TestCase(name: "hash58: verifica el iTunesDB real") {
            let env = try skipUnless("CONNECTOR_REAL_IPOD_CONTROL", "CONNECTOR_REAL_GUID")
            let url = URL(fileURLWithPath: env[0]).appendingPathComponent("iTunes/iTunesDB")
            let data = try Data(contentsOf: url)
            guard let g = Hash58.parseGUID(env[1]) else {
                expect(false, "GUID no válido")
                return
            }
            expect(Hash58.verify(data, guid: g))
        },
    ]
}
