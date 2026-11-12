import Foundation

public enum DeviceError: Error {
    case noGUID
    case guidUnverified
    case ejectFailed(String)
}

public struct IPodDevice: Sendable {
    public let volume: URL
    public var name: String
    public var modelNumber: String?
    public var capacityBytes: Int64
    public var freeBytes: Int64

    public init(volume: URL, name: String, modelNumber: String?, capacityBytes: Int64, freeBytes: Int64) {
        self.volume = volume
        self.name = name
        self.modelNumber = modelNumber
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
    }

    public var controlDir: URL { volume.appendingPathComponent("iPod_Control", isDirectory: true) }

    public static func discover(in volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> [IPodDevice] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let entries = try? fm.contentsOfDirectory(at: volumesRoot, includingPropertiesForKeys: keys, options: []) else { return [] }
        var result: [IPodDevice] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let control = url.appendingPathComponent("iPod_Control", isDirectory: true)
            var isDir: ObjCBool = false
            let hasMarker = ["Device", "iTunes"].contains { fm.fileExists(atPath: control.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue }
            guard hasMarker else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            let free = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
            var device = IPodDevice(
                volume: url,
                name: url.lastPathComponent,
                modelNumber: nil,
                capacityBytes: total,
                freeBytes: free
            )
            device.modelNumber = GUIDResolver.sysInfoValue("ModelNumStr", for: device)
            result.append(device)
        }
        return result
    }
}
