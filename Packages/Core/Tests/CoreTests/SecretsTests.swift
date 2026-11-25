import XCTest
@testable import Core

final class SecretsTests: XCTestCase {
    private let nowhere = URL(fileURLWithPath: "/nonexistent")

    private func file(_ contents: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-secrets-\(UUID().uuidString).env")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    func testEnvironmentWinsOverTheKeychainAndTheFile() throws {
        var askedKeychain = false
        let key = try Secrets.openAIAPIKey(
            environment: ["OPENAI_API_KEY": "from-env"],
            keychain: { askedKeychain = true; return .found("from-keychain") },
            file: try file("OPENAI_API_KEY=from-file\n"))
        XCTAssertEqual(key, "from-env")
        XCTAssertFalse(askedKeychain, "the Keychain prompt is never raised when the environment has a key")
    }

    func testKeychainWinsOverTheFile() throws {
        let key = try Secrets.openAIAPIKey(
            environment: [:], keychain: { .found("from-keychain") },
            file: try file("OPENAI_API_KEY=from-file\n"))
        XCTAssertEqual(key, "from-keychain")
    }

    func testEmptyEnvironmentFallsThroughToTheKeychain() throws {
        let key = try Secrets.openAIAPIKey(
            environment: ["OPENAI_API_KEY": ""], keychain: { .found("from-keychain") }, file: nowhere)
        XCTAssertEqual(key, "from-keychain")
    }

    func testReadsTheFileWhenTheKeychainHasNone() throws {
        let file = try file("# comment\nexport OPENAI_API_KEY=\"from-file\"\n")
        XCTAssertEqual(
            try Secrets.openAIAPIKey(environment: [:], keychain: { .missing }, file: file),
            "from-file")
    }

    func testReadsTheFileWhenTheKeychainIsDenied() throws {
        let file = try file("OPENAI_API_KEY=from-file\n")
        XCTAssertEqual(
            try Secrets.openAIAPIKey(environment: [:], keychain: { .denied }, file: file),
            "from-file")
    }

    func testMissingKeyNamesWhereItLooked() {
        XCTAssertThrowsError(
            try Secrets.openAIAPIKey(
                environment: [:], keychain: { .missing }, file: URL(fileURLWithPath: "/nope"))
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("No OPENAI_API_KEY in the environment, the login Keychain (service OPENAI_API_KEY, account \(NSUserName())) or /nope."), message)
            XCTAssertTrue(message.contains("Always Allow"), message)
        }
    }

    func testDeniedKeySaysToAllowYap() {
        XCTAssertThrowsError(
            try Secrets.openAIAPIKey(environment: [:], keychain: { .denied }, file: nowhere)
        ) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Yap isn't allowed to read the login Keychain"))
        }
    }

    func testHasKeyChecksEachPlaceWithoutReadingTheSecret() throws {
        XCTAssertTrue(Secrets.hasOpenAIAPIKey(environment: ["OPENAI_API_KEY": "x"], keychain: { false }, file: nowhere))
        XCTAssertTrue(Secrets.hasOpenAIAPIKey(environment: [:], keychain: { true }, file: nowhere))
        XCTAssertTrue(Secrets.hasOpenAIAPIKey(environment: [:], keychain: { false }, file: try file("OPENAI_API_KEY=k\n")))
        XCTAssertFalse(Secrets.hasOpenAIAPIKey(environment: [:], keychain: { false }, file: nowhere))
    }

    func testTheKeychainItemIsTheOneSecurityReads() {
        XCTAssertEqual(Secrets.keychainItem, KeychainItem(service: "OPENAI_API_KEY", account: NSUserName()))
    }
}
