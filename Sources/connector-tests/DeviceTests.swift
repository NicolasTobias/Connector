import Foundation
import ConnectorCore

enum DeviceTests {
    static let good: [UInt8] = [0x00, 0x0A, 0x27, 0x00, 0x12, 0x34, 0xAB, 0xCD]
    static let bad: [UInt8] = [0x00, 0x0A, 0x27, 0x00, 0x99, 0x99, 0x99, 0x99]

    static func fakeDevice(in root: URL, name: String = "IPOD") throws -> IPodDevice {
        let volume = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: volume.appendingPathComponent("iPod_Control/Device"), withIntermediateDirectories: true)
        return IPodDevice(volume: volume, name: name, modelNumber: nil, capacityBytes: 0, freeBytes: 0)
    }

    static func writeExtended(_ d: IPodDevice, _ hex: String) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>FireWireGUID</key><string>\(hex)</string></dict></plist>
        """
        try xml.write(to: d.controlDir.appendingPathComponent("Device/SysInfoExtended"), atomically: true, encoding: .utf8)
    }

    static func writeSysInfo(_ d: IPodDevice, _ hex: String) throws {
        try "ModelNumStr: xA446\nFirewireGuid: 0x\(hex)\n".write(to: d.controlDir.appendingPathComponent("Device/SysInfo"), atomically: true, encoding: .utf8)
    }

    static func signedDB(guid: [UInt8]) throws -> Data {
        var db = ITunesDB.makeEmpty().serialize()
        try Hash58.sign(&db, guid: guid)
        return db
    }

    static let all: [TestCase] = [
        TestCase(name: "device: detecta volumen con iPod_Control") {
            let root = try tempDir()
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("IPOD/iPod_Control/iTunes"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("OTRO"), withIntermediateDirectories: true)
            let found = IPodDevice.discover(in: root)
            expectEqual(found.count, 1)
            expectEqual(found.first?.name ?? "", "IPOD")
        },
        TestCase(name: "device: GUID desde SysInfoExtended") {
            let d = try fakeDevice(in: try tempDir())
            try writeExtended(d, "000A27001234ABCD")
            expectEqual(GUIDResolver.candidates(for: d).first ?? [], good)
            try writeExtended(d, "0x000a27001234abcd")
            expectEqual(GUIDResolver.candidates(for: d).first ?? [], good)
        },
        TestCase(name: "device: SysInfo en texto") {
            let d = try fakeDevice(in: try tempDir())
            try writeSysInfo(d, "000A27001234ABCD")
            expectEqual(GUIDResolver.candidates(for: d).first ?? [], good)
        },
        TestCase(name: "device: elige el candidato que verifica") {
            let d = try fakeDevice(in: try tempDir())
            try writeExtended(d, "000A270099999999")
            try writeSysInfo(d, "000A27001234ABCD")
            let db = try signedDB(guid: good)
            expectEqual(GUIDResolver.candidates(for: d).first ?? [], bad)
            expectEqual(try GUIDResolver.resolve(for: d, existingDB: db), good)
        },
        TestCase(name: "device: ningún candidato verifica") {
            let d = try fakeDevice(in: try tempDir())
            try writeSysInfo(d, "000A270099999999")
            let db = try signedDB(guid: good)
            await expectThrows { _ = try GUIDResolver.resolve(for: d, existingDB: db) }
            do { _ = try GUIDResolver.resolve(for: d, existingDB: db) } catch let e as DeviceError {
                expect({ if case .guidUnverified = e { return true } else { return false } }(), "\(e)")
            }
        },
        TestCase(name: "device: sin candidatos y sin base lanza noGUID") {
            let d = try fakeDevice(in: try tempDir())
            do { _ = try GUIDResolver.resolve(for: d, existingDB: nil); expect(false, "debía lanzar") }
            catch let e as DeviceError { expect({ if case .noGUID = e { return true } else { return false } }(), "\(e)") }
        },
    ]
}
