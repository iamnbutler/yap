import Foundation

/// Where Yap keeps things on disk: `~/Library/Application Support/yap`.
public enum Paths {
    public static var support: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yap", isDirectory: true)
    }

    /// Local secrets as `KEY=value` lines. Mode 600, never in the repo.
    public static var secretsFile: URL {
        support.appendingPathComponent("secrets.env")
    }
}
