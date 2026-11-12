import Foundation

struct TestCase: Sendable {
    let name: String
    let body: @Sendable () async throws -> Void
}

public struct Skip: Error {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

nonisolated(unsafe) var testFailures: [String] = []

private func location(_ file: StaticString, _ line: UInt) -> String {
    "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)"
}

func expect(_ c: Bool, _ msg: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if !c {
        let detail = msg()
        testFailures.append("\(location(file, line)): \(detail.isEmpty ? "condición falsa" : detail)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    let prefix = msg()
    expect(a == b, "\(prefix.isEmpty ? "" : prefix + ": ")esperaba \(b), obtuve \(a)", file: file, line: line)
}

func expectThrows(_ body: () async throws -> Void, _ msg: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) async {
    do {
        try await body()
        expect(false, "\(msg()) se esperaba un error", file: file, line: line)
    } catch {
    }
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("connector-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

public func skipUnless(_ env: String...) throws -> [String] {
    let environment = ProcessInfo.processInfo.environment
    let values = env.map { environment[$0] ?? "" }
    if let index = values.firstIndex(where: { $0.isEmpty }) {
        throw Skip("falta la variable de entorno \(env[index])")
    }
    return values
}
