import XCTest
@testable import LocalCaptions

final class WorkerPipeTests: XCTestCase {
    /// After the worker exits its pipes report end of stream forever; the reader must let go.
    func testReaderDetachesAtEndOfStream() throws {
        let pipe = Pipe()
        let received = expectation(description: "data delivered")
        let collected = Collected()
        pipe.fileHandleForReading.readabilityHandler = LocalWorker.reader { data in
            collected.append(data); received.fulfill()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        wait(for: [received], timeout: 2)
        try pipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2)
        while pipe.fileHandleForReading.readabilityHandler != nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler)
        XCTAssertEqual(String(data: collected.data, encoding: .utf8), "ready\n")
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    var data: Data { lock.withLock { stored } }
    func append(_ data: Data) { lock.withLock { stored.append(data) } }
}
