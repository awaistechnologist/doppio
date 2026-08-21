import Foundation

/// Every filesystem location Doppio is allowed to touch.
///
/// The security requirement in the spec (§7) is that Doppio never writes
/// outside these three roots plus the wrappers it generates. Centralising the
/// paths here makes that auditable.
public enum DoppioPaths {
    public static let stubVersion = "0.5.0"
    public static let appVersion = "0.5.0"

    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Where generated Shots live: `~/Applications/Doppio/`
    public static var shotsDirectory: URL {
        home.appendingPathComponent("Applications/Doppio", isDirectory: true)
    }

    /// Doppio's own support directory.
    public static var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Doppio", isDirectory: true)
    }

    /// Per-Shot isolated data roots.
    public static var dataRoot: URL {
        supportDirectory.appendingPathComponent("Shots", isDirectory: true)
    }

    public static func defaultDataDir(for id: UUID) -> URL {
        dataRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// The Shot library index.
    public static var libraryFile: URL {
        supportDirectory.appendingPathComponent("library.json")
    }

    /// User-installed compatibility rules, layered over the bundled ones.
    public static var userRulesFile: URL {
        supportDirectory.appendingPathComponent("rules.json")
    }

    /// Location of `shot.json` inside a generated wrapper.
    ///
    /// Deliberately *not* `Contents/Resources` — in `link` mode that path is a
    /// symlink into the target app. `Contents/Doppio` is also chosen over
    /// `Contents/*.resources` because `codesign` treats a `.resources`
    /// directory as a nested bundle and refuses to sign it.
    public static func configFile(inWrapper wrapper: URL) -> URL {
        wrapper.appendingPathComponent("Contents/Doppio/shot.json")
    }

    public static func ensureDirectories() throws {
        for dir in [shotsDirectory, supportDirectory, dataRoot] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
