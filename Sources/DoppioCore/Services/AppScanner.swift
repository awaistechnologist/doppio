import Foundation
import AppKit

/// Finds installed applications the user can make a Shot of.
public struct AppScanner: Sendable {
    public init() {}

    static let searchPaths: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    /// All installed apps, de-duplicated by bundle ID and sorted by name.
    /// Doppio's own Shots are excluded — a Shot of a Shot is not useful.
    public func scan() -> [TargetApp] {
        var byID: [String: TargetApp] = [:]
        let fm = FileManager.default

        for root in Self.searchPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(entry)
                guard let app = Self.target(at: url) else { continue }
                if app.bundleID.hasPrefix("org.doppio-mac") { continue }
                if byID[app.bundleID] == nil { byID[app.bundleID] = app }
            }
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads the facts Doppio needs out of an app bundle.
    public static func target(at url: URL) -> TargetApp? {
        guard let info = BundleInspector.plist(at: url.appendingPathComponent("Contents/Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String,
              let executable = info["CFBundleExecutable"] as? String
        else { return nil }

        let display = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        // CFBundleName must be preserved verbatim in the wrapper (Electron
        // derives its helper app names from it), so fall back to the on-disk
        // name only when the key is genuinely absent.
        let bundleName = (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        return TargetApp(
            bundleID: bundleID,
            name: display,
            bundleName: bundleName,
            executableName: executable,
            path: url.path,
            version: info["CFBundleShortVersionString"] as? String
        )
    }

    /// Resolves a target by bundle ID, falling back to a recorded path.
    /// Shots resolve at every launch so they survive the target moving.
    public static func resolve(bundleID: String?, fallbackPath: String?) -> TargetApp? {
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let app = target(at: url) {
            return app
        }
        if let fallbackPath {
            let url = URL(fileURLWithPath: fallbackPath)
            if FileManager.default.fileExists(atPath: url.path) { return target(at: url) }
        }
        return nil
    }

    /// Case-insensitive lookup by display name or bundle ID, for the CLI.
    public func find(_ needle: String) -> TargetApp? {
        let apps = scan()
        if let exact = apps.first(where: { $0.bundleID.caseInsensitiveCompare(needle) == .orderedSame }) {
            return exact
        }
        if let byName = apps.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame }) {
            return byName
        }
        return apps.first { $0.name.localizedCaseInsensitiveContains(needle) }
    }
}
