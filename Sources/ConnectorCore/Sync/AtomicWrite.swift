import Foundation

public enum AtomicWrite {
    public static func replace(_ url: URL, with data: Data) throws {
        try replace(url, with: data, beforeRename: {})
    }

    static func replace(_ url: URL, with data: Data, beforeRename: () throws -> Void) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp-connector")
        do {
            try? fm.removeItem(at: tmp)
            guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try beforeRename()
            guard rename(tmp.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}
