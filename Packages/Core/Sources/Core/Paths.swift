import Foundation

/// Where Yap keeps things on disk: `~/Library/Application Support/yap` on the
/// Mac, and the same path inside the app group's container on iOS.
public enum Paths {
    /// The container the iOS app and its keyboard share. An extension is
    /// sandboxed apart from its app, and this is the only directory both see.
    public static let appGroup = "group.dev.yap.Yap"

    public static var support: URL {
        #if os(iOS)
            if let group = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup)
            {
                return group.appendingPathComponent(
                    "Library/Application Support/yap", isDirectory: true)
            }
        #endif
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yap", isDirectory: true)
    }

    /// Local secrets as `KEY=value` lines. Mode 600, never in the repo.
    public static var secretsFile: URL {
        support.appendingPathComponent("secrets.env")
    }
}
