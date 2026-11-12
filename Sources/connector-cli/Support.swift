import Foundation
import ConnectorCore

struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct Arguments {
    var positional: [String] = []
    var volume: String?

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if item == "--volume" {
                guard index + 1 < raw.count else { throw CLIError("Missing path after --volume.") }
                volume = raw[index + 1]
                index += 2
            } else if item.hasPrefix("--volume=") {
                volume = String(item.dropFirst("--volume=".count))
                index += 1
            } else if item.hasPrefix("--") {
                throw CLIError("Unknown option: \(item)")
            } else {
                positional.append(item)
                index += 1
            }
        }
    }
}

func resolveDevice(_ volume: String?) throws -> IPodDevice {
    if let volume {
        let url = URL(fileURLWithPath: (volume as NSString).expandingTildeInPath).standardizedFileURL
        let found = IPodDevice.discover(in: url.deletingLastPathComponent())
        guard let device = found.first(where: { $0.volume.standardizedFileURL.path == url.path }) else {
            throw CLIError("\(url.path) doesn't look like an iPod (missing iPod_Control with Device or iTunes).")
        }
        return device
    }
    let found = IPodDevice.discover()
    switch found.count {
    case 1: return found[0]
    case 0: throw CLIError("No iPod found in /Volumes.")
    default:
        let list = found.map { "  \($0.volume.path)" }.joined(separator: "\n")
        throw CLIError("More than one iPod found; pick one with --volume:\n\(list)")
    }
}

func readFile(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
}

func dbURL(_ d: IPodDevice) -> URL { d.controlDir.appendingPathComponent("iTunes/iTunesDB") }
func artworkURL(_ d: IPodDevice) -> URL { d.controlDir.appendingPathComponent("Artwork/ArtworkDB") }

func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func gigabytes(_ bytes: Int64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
}

func duration(ms: UInt32) -> String {
    let seconds = Int(ms) / 1000
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

struct ByteDifference {
    let offset: Int
    let original: [UInt8]
    let rewritten: [UInt8]
}

func firstDifference(_ a: Data, _ b: Data, context: Int = 16) -> ByteDifference? {
    let x = [UInt8](a), y = [UInt8](b)
    let common = min(x.count, y.count)
    var offset = 0
    while offset < common && x[offset] == y[offset] { offset += 1 }
    if offset == common && x.count == y.count { return nil }
    func window(_ v: [UInt8]) -> [UInt8] {
        let lo = max(0, offset - context), hi = min(v.count, offset + context)
        return lo < hi ? Array(v[lo..<hi]) : []
    }
    return ByteDifference(offset: offset, original: window(x), rewritten: window(y))
}

func roundTripReport(_ label: String, _ data: Data) -> (ok: Bool, lines: [String]) {
    let chunk: Chunk
    do { chunk = try Chunk.parse(data) } catch {
        return (false, ["\(label) cycle: different (couldn't read: \(error))"])
    }
    guard let diff = firstDifference(data, chunk.serialize()) else { return (true, ["\(label) cycle: identical"]) }
    return (false, [
        "\(label) cycle: different",
        "First differing byte: \(diff.offset)",
        "Original: \(hex(diff.original))",
        "Rewritten: \(hex(diff.rewritten))",
    ])
}
