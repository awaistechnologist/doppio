import Foundation

/// `shot.json`, as written by Doppio's BundleForge.
///
/// Deliberately duplicated rather than shared with DoppioCore: the stub is
/// embedded in every Shot and must stay tiny and dependency-free, and it has to
/// keep working when Doppio.app is deleted.
struct LaunchPlan: Codable {
    var schema: Int
    var shotID: String
    var name: String
    var mode: String
    var launchMode: String
    var strategy: String
    var execPath: String?
    var targetBundleID: String?
    var targetPath: String?
    var targetExecutableName: String?
    var args: [String]
    var env: [String: String]
    var dataDir: String
    var url: String?
    var documentPath: String?
    var ephemeral: Bool
    var statusItem: Bool
    var stubVersion: String

    /// Reads the plan from `Contents/Doppio/shot.json`, located relative to the
    /// running executable rather than via `Bundle.main` — in `link` mode
    /// `Contents/Resources` is a symlink into the target app.
    static func load() throws -> (plan: LaunchPlan, wrapper: URL) {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let contents = executable
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
        let wrapper = contents.deletingLastPathComponent()
        let configURL = contents.appendingPathComponent("Doppio/shot.json")
        let data = try Data(contentsOf: configURL)
        return (try JSONDecoder().decode(LaunchPlan.self, from: data), wrapper)
    }
}

enum StubLog {
    /// Diagnostics go to stderr, which lands in Console.app for a GUI launch.
    static func note(_ message: String) {
        FileHandle.standardError.write("doppio-shot: \(message)\n".data(using: .utf8)!)
    }
}
