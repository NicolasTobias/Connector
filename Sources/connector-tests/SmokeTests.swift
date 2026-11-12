import Foundation
import ConnectorCore

enum SmokeTests {
    static let all: [TestCase] = [
        TestCase(name: "smoke: versión") {
            expectEqual(connectorVersion, "0.2.1")
        },
        TestCase(name: "smoke: el runner detecta fallos") {
            if ProcessInfo.processInfo.environment["CONNECTOR_SELFTEST_FAIL"] == "1" {
                expect(false, "autofallo a propósito")
            }
        },
    ]
}
