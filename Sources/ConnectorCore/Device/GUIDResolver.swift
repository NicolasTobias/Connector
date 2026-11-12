import Foundation
import IOKit

public enum GUIDResolver {
    public static func candidates(for d: IPodDevice) -> [[UInt8]] {
        var result: [[UInt8]] = []
        for guid in [fromSysInfoExtended(d), fromSysInfo(d), fromIORegistry(d)] {
            if let guid, !result.contains(guid) { result.append(guid) }
        }
        return result
    }

    public static func resolve(for d: IPodDevice, existingDB: Data?) throws -> [UInt8] {
        let all = candidates(for: d)
        if let db = existingDB {
            guard let match = all.first(where: { Hash58.verify(db, guid: $0) }) else { throw DeviceError.guidUnverified }
            return match
        }
        guard let first = all.first else { throw DeviceError.noGUID }
        return first
    }

    static func sysInfoValue(_ key: String, for d: IPodDevice) -> String? {
        let url = d.controlDir.appendingPathComponent("Device/SysInfo")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare(key) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func fromSysInfoExtended(_ d: IPodDevice) -> [UInt8]? {
        let url = d.controlDir.appendingPathComponent("Device/SysInfoExtended")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let hex = plist["FireWireGUID"] as? String else { return nil }
        return Hash58.parseGUID(hex)
    }

    private static func fromSysInfo(_ d: IPodDevice) -> [UInt8]? {
        sysInfoValue("FirewireGuid", for: d).flatMap(Hash58.parseGUID)
    }

    private static func fromIORegistry(_ d: IPodDevice) -> [UInt8]? {
        guard let serial = usbSerial(forVolume: d.volume) else { return nil }
        let hex = serial.filter(\.isHexDigit)
        guard hex.count >= 16 else { return nil }
        return Hash58.parseGUID(String(hex.prefix(16)))
    }

    private static func usbSerial(forVolume volume: URL) -> String? {
        var fs = statfs()
        guard statfs(volume.path, &fs) == 0 else { return nil }
        let device = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard device.hasPrefix("/dev/") else { return nil }
        let bsd = String(device.dropFirst(5))
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var current = service
        IOObjectRetain(current)
        while true {
            if let value = serialProperty(of: current) {
                IOObjectRelease(current)
                return value
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard status == KERN_SUCCESS else { return nil }
            current = parent
        }
    }

    private static func serialProperty(of entry: io_registry_entry_t) -> String? {
        for key in ["kUSBSerialNumberString", "USB Serial Number"] {
            if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                return value
            }
        }
        return nil
    }
}
