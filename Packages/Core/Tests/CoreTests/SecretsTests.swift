import XCTest
@testable import Core

final class SecretsTests: XCTestCase {
    func testEnvironmentWinsOverTheFile() throws {
        let key = try Secrets.openAIAPIKey(
            environment: ["OPENAI_API_KEY": "from-env"],
            file: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(key, "from-env")
    }

    func testReadsTheFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-secrets-\(UUID().uuidString).env")
        try "# comment\nexport OPENAI_API_KEY=\"from-file\"\n".write(
            to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(try Secrets.openAIAPIKey(environment: [:], file: file), "from-file")
    }

    func testMissingKeyNamesWhereItLooked() {
        XCTAssertThrowsError(
            try Secrets.openAIAPIKey(environment: [:], file: URL(fileURLWithPath: "/nope"))
        ) { error in
            XCTAssertEqual(
                error.localizedDescription, "No OPENAI_API_KEY in the environment or /nope")
        }
    }
}
