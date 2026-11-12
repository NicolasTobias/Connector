import Foundation

public enum CoverLocator {
    public static func cover(for info: MediaInfo) -> Data? {
        if let embedded = info.cover { return embedded }
        let directory = info.url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let byLowercase = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for base in ["cover", "folder", "front"] {
            for ext in ["jpg", "jpeg", "png"] {
                if let name = byLowercase["\(base).\(ext)"],
                   let data = try? Data(contentsOf: directory.appendingPathComponent(name)) {
                    return data
                }
            }
        }
        return nil
    }
}
