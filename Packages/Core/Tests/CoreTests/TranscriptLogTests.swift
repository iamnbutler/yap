import XCTest
@testable import Core

final class TranscriptLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-transcripts-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func day(_ offset: Int, from now: Date = .now) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now)!
    }

    func testRecentIsNewestFirstAcrossDays() throws {
        let log = TranscriptLog(directory: directory)
        try log.append(Transcript(date: day(-2), text: "oldest"))
        try log.append(Transcript(date: day(-1), text: "middle"))
        try log.append(Transcript(date: .now, text: "newer"))
        try log.append(Transcript(date: .now, text: "newest", app: "Ghostty", typed: true))

        let recent = log.recent(3)
        XCTAssertEqual(recent.map(\.text), ["newest", "newer", "middle"])
        XCTAssertEqual(recent.first?.app, "Ghostty")
        XCTAssertEqual(recent.first?.typed, true)
        XCTAssertEqual(log.dayFiles().count, 3)
    }

    func testTextSurvivesNewlinesAndQuotes() throws {
        let log = TranscriptLog(directory: directory)
        let text = "first line\nsecond \"quoted\" line"
        try log.append(Transcript(text: text))
        XCTAssertEqual(log.recent(1).first?.text, text)
    }

    func testAGarbledLineCostsOnlyThatLine() throws {
        let log = TranscriptLog(directory: directory)
        try log.append(Transcript(text: "kept"))
        let file = log.dayFiles()[0]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"half a line\n".utf8))
        try handle.close()

        XCTAssertEqual(log.recent(5).map(\.text), ["kept"])
    }

    func testPruneKeepsTheRetentionWindow() throws {
        let log = TranscriptLog(directory: directory)
        for offset in [-40, -30, -29, -1, 0] {
            try log.append(Transcript(date: day(offset), text: "day \(offset)"))
        }

        log.prune(keepingDays: 30)

        XCTAssertEqual(
            Set(log.recent(10).map(\.text)), ["day -29", "day -1", "day 0"])
    }

    func testAnEmptyDirectoryHasNothingRecent() {
        XCTAssertEqual(TranscriptLog(directory: directory).recent(5), [])
    }
}

final class ConfigTests: XCTestCase {
    func testMissingFileAndMissingKeysUseDefaults() throws {
        XCTAssertEqual(try Config.load(from: URL(fileURLWithPath: "/nonexistent")), Config())

        let partial = try JSONDecoder().decode(Config.self, from: Data(#"{"retentionDays": 7}"#.utf8))
        XCTAssertEqual(partial.retentionDays, 7)
        XCTAssertTrue(partial.keepTranscripts)
    }

    func testSaveRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-config-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var config = Config()
        config.keepTranscripts = false
        config.retentionDays = 90
        try config.save(to: url)

        XCTAssertEqual(try Config.load(from: url), config)
    }

    func testABrokenFileIsReportedNotReplaced() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json".utf8).write(to: url)

        XCTAssertThrowsError(try Config.load(from: url))
    }
}

final class HotkeyTests: XCTestCase {
    func testModifiersByNameAndAlias() {
        XCTAssertEqual(Hotkey("rightCommand"), .rightCommand)
        XCTAssertEqual(Hotkey("Right Command"), .rightCommand)
        XCTAssertEqual(Hotkey("rcmd"), .rightCommand)
        XCTAssertEqual(Hotkey("right_alt")?.name, "Right Option")
        XCTAssertEqual(Hotkey("fn")?.keyCode, 63)
        XCTAssertTrue(Hotkey("leftShift")?.isModifier == true)
    }

    func testEachSideHasItsOwnFlag() {
        // Releasing Right Command while Left Command is held must still read
        // as a release, so the two cannot share the Command flag.
        XCTAssertEqual(Hotkey.rightCommand.modifierFlag, 0x10)
        XCTAssertEqual(Hotkey("leftCommand")?.modifierFlag, 0x08)
        XCTAssertNotEqual(Hotkey("rightOption")?.modifierFlag, Hotkey("leftOption")?.modifierFlag)
    }

    func testOrdinaryKeys() {
        let f13 = Hotkey("F13")
        XCTAssertEqual(f13?.keyCode, 105)
        XCTAssertEqual(f13?.name, "F13")
        XCTAssertEqual(f13?.isModifier, false)
        XCTAssertNil(Hotkey("f21"))
        XCTAssertEqual(Hotkey("keycode:105")?.keyCode, 105)
        // A modifier's code is still that modifier.
        XCTAssertEqual(Hotkey("keycode:54"), .rightCommand)
    }

    func testUnknownNamesAreNil() {
        XCTAssertNil(Hotkey("hyper"))
        XCTAssertNil(Hotkey(""))
    }

    func testConfigDefaultsToRightCommand() throws {
        XCTAssertEqual(Config().hotkey, .rightCommand)
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"key": "f13"}"#.utf8))
        XCTAssertEqual(config.hotkey?.name, "F13")
    }
}
