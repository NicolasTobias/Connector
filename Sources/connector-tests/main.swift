import Foundation

let allTests = SmokeTests.all + ChunkTests.all + Hash58Tests.all + ITunesDBTests.all + PlayCountsTests.all + DeviceTests.all + MediaTests.all + TranscoderTests.all + ArtworkTests.all + SyncTests.all + AppModelTests.all + LibraryTests.all
let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let selected = allTests.filter { filter.isEmpty || $0.name.contains(filter) }
var failedCount = 0
var skippedCount = 0
for test in selected {
    testFailures = []
    do {
        try await test.body()
        for failure in testFailures {
            print("FALLO \(test.name)\n  \(failure)")
        }
        if !testFailures.isEmpty { failedCount += 1 }
    } catch let skip as Skip {
        skippedCount += 1
        print("OMITIDO \(test.name): \(skip.reason)")
    } catch {
        failedCount += 1
        print("FALLO \(test.name): error no esperado: \(error)")
    }
}
print("\(selected.count) tests, \(failedCount) fallos, \(skippedCount) omitidos")
exit(failedCount > 0 ? 1 : 0)
