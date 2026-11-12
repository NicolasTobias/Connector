import Foundation

let usage = """
Usage: connector-cli <command> [options]

Commands:
  info                       iPod details and GUID status
  verify                     Read-only checks of iTunesDB and ArtworkDB
  list                       List tracks (id, artist — title, album, duration)
  export-control <dest>      Copy iPod_Control without Music for the real-data tests
  add <paths...>             Add music to the iPod
  rm <id...>                 Remove tracks by id
  eject                      Eject the iPod

Options:
  --volume <path>            iPod volume (defaults to the only one in /Volumes)
  --help                     Show this help
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}

func run() async throws {
    let raw = Array(CommandLine.arguments.dropFirst())
    guard let command = raw.first else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(1)
    }
    if command == "--help" || command == "-h" || command == "help" {
        print(usage)
        exit(0)
    }
    guard ["info", "verify", "list", "export-control", "add", "rm", "eject"].contains(command) else {
        FileHandle.standardError.write(Data("Unknown command: \(command)\n\(usage)\n".utf8))
        exit(1)
    }
    let args = try Arguments(Array(raw.dropFirst()))
    let device = try resolveDevice(args.volume)
    switch command {
    case "info": try runInfo(device)
    case "verify": try runVerify(device)
    case "list": try await runList(device)
    case "export-control":
        guard args.positional.count == 1 else { throw CLIError("Usage: export-control <destination>") }
        try runExport(device, destination: args.positional[0])
    case "add": try await runAdd(device, paths: args.positional)
    case "rm": try await runRemove(device, ids: args.positional)
    default: try await runEject(device)
    }
}

do { try await run() } catch let error as CLIError { fail(error.message) } catch { fail("\(error)") }
