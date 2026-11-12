import Foundation
import DiskArbitration

public enum Ejector {
    private final class Box: @unchecked Sendable {
        let continuation: CheckedContinuation<Void, Error>
        init(_ c: CheckedContinuation<Void, Error>) { continuation = c }
    }

    public static func eject(_ d: IPodDevice) async throws {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, d.volume as CFURL) else {
            throw DeviceError.ejectFailed("Couldn't access the disk of \(d.name).")
        }
        let target = DADiskCopyWholeDisk(disk) ?? disk
        let queue = DispatchQueue(label: "connector.eject")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        try await step(target, unmount: true)
        try await step(target, unmount: false)
    }

    private static func step(_ disk: DADisk, unmount: Bool) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let box = Unmanaged.passRetained(Box(c)).toOpaque()
            let callback: DADiskUnmountCallback = { _, dissenter, context in
                let box = Unmanaged<Box>.fromOpaque(context!).takeRetainedValue()
                if let dissenter {
                    let status = DADissenterGetStatusString(dissenter) as String?
                    box.continuation.resume(throwing: DeviceError.ejectFailed(status ?? "The system didn't allow ejecting the iPod."))
                } else {
                    box.continuation.resume()
                }
            }
            if unmount {
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), callback, box)
            } else {
                DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), callback, box)
            }
        }
    }
}
