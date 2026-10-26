import XCTest
@testable import Core

final class BridgeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-bridge-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStateRoundTrips() throws {
        XCTAssertNil(Bridge.State.read(from: directory))
        let state = Bridge.State(
            phase: .recording, preview: "hello there", message: nil,
            expires: Date(timeIntervalSince1970: 1_800_000_000),
            updated: Date(timeIntervalSince1970: 1_799_999_000))
        try state.write(to: directory)
        XCTAssertEqual(Bridge.State.read(from: directory), state)
    }

    func testAResultIsClaimedOnce() throws {
        try Bridge.deliver(Bridge.Result(text: "only once"), in: directory)
        XCTAssertEqual(Bridge.claim(in: directory)?.text, "only once")
        XCTAssertNil(Bridge.claim(in: directory))
    }

    func testResultsAreClaimedOldestFirst() throws {
        let now = Date.now
        try Bridge.deliver(Bridge.Result(text: "second", date: now.addingTimeInterval(-5)), in: directory)
        try Bridge.deliver(Bridge.Result(text: "first", date: now.addingTimeInterval(-10)), in: directory)
        XCTAssertEqual(Bridge.claim(in: directory, now: now)?.text, "first")
        XCTAssertEqual(Bridge.claim(in: directory, now: now)?.text, "second")
    }

    func testStaleResultsAreDroppedUnread() throws {
        let now = Date.now
        try Bridge.deliver(
            Bridge.Result(text: "for another field", date: now.addingTimeInterval(-Bridge.resultLifetime - 1)),
            in: directory)
        try Bridge.deliver(Bridge.Result(text: "fresh", date: now), in: directory)
        XCTAssertEqual(Bridge.claim(in: directory, now: now)?.text, "fresh")
        XCTAssertNil(Bridge.claim(in: directory, now: now))
        let left = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("results").path)
        XCTAssertEqual(left, [])
    }

    func testObserverHearsAPost() {
        let heard = expectation(description: "ping")
        let observer = Bridge.observe(.ping, queue: .global()) { heard.fulfill() }
        Bridge.post(.ping)
        wait(for: [heard], timeout: 2)
        _ = observer
    }
}
