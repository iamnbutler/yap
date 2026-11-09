import Foundation
import Synchronization
import XCTest
@testable import Core

/// A store in memory, standing in for the Keychain.
final class MemoryStore: SecretStore {
    let value: Mutex<String?>
    init(_ value: String? = nil) { self.value = Mutex(value) }
    func read() throws -> String? { value.withLock { $0 } }
    var exists: Bool { value.withLock { $0 != nil } }
    func save(_ new: String) throws { value.withLock { $0 = new } }
    func delete() throws { value.withLock { $0 = nil } }
}

final class SecretsTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-secrets-\(UUID().uuidString).env")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    func testEnvironmentWinsOverTheStore() throws {
        let key = try Secrets.openAIAPIKey(
            environment: ["OPENAI_API_KEY": "from-env"], store: MemoryStore("stored"))
        XCTAssertEqual(key, "from-env")
    }

    func testReadsTheStore() throws {
        XCTAssertEqual(try Secrets.openAIAPIKey(environment: [:], store: MemoryStore("stored")), "stored")
        XCTAssertTrue(Secrets.hasOpenAIAPIKey(environment: [:], store: MemoryStore("stored")))
    }

    func testMissingKeySaysWhereToSetIt() {
        XCTAssertFalse(Secrets.hasOpenAIAPIKey(environment: [:], store: MemoryStore()))
        XCTAssertThrowsError(try Secrets.openAIAPIKey(environment: [:], store: MemoryStore())) {
            XCTAssertEqual(
                $0.localizedDescription, "No OpenAI key: set one with OpenAI Key in Yap's menu")
        }
    }

    func testMigrationImportsAndDeletesAFileWithOnlyTheKey() throws {
        try "# comment\nexport OPENAI_API_KEY=\"from-file\"\n".write(
            to: file, atomically: true, encoding: .utf8)
        let store = MemoryStore()

        XCTAssertEqual(try Secrets.migrateOpenAIKey(from: file, into: store), .imported)
        XCTAssertEqual(try store.read(), "from-file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMigrationKeepsOtherLines() throws {
        try "OPENAI_API_KEY=sk-1\nOTHER=x\n".write(to: file, atomically: true, encoding: .utf8)
        let store = MemoryStore()

        XCTAssertEqual(try Secrets.migrateOpenAIKey(from: file, into: store), .imported)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "OTHER=x\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        XCTAssertEqual(mode as? Int, 0o600)
    }

    func testMigrationLeavesAnExistingKeyAndStillCleansTheFile() throws {
        try "OPENAI_API_KEY=old\n".write(to: file, atomically: true, encoding: .utf8)
        let store = MemoryStore("current")

        XCTAssertEqual(try Secrets.migrateOpenAIKey(from: file, into: store), .dropped)
        XCTAssertEqual(try store.read(), "current")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMigrationWithNoFileDoesNothing() throws {
        let store = MemoryStore()
        XCTAssertEqual(try Secrets.migrateOpenAIKey(from: file, into: store), .nothing)
        XCTAssertNil(try store.read())
    }

    func testMigrationLeavesTheFileWhenSavingFails() throws {
        struct Refusing: SecretStore {
            func read() throws -> String? { nil }
            var exists: Bool { false }
            func save(_ value: String) throws { throw KeychainError(status: errSecAuthFailed) }
            func delete() throws {}
        }
        try "OPENAI_API_KEY=sk-1\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Secrets.migrateOpenAIKey(from: file, into: Refusing()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
