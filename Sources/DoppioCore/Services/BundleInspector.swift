import Foundation

/// Reads facts about a target app bundle: which frameworks it embeds and
/// whether it is sandboxed. Both drive rule selection.
public struct BundleInspector: Sendable {
    public var frameworks: Set<String>
    public var sandboxed: Bool
    public var executableName: String?
    public var bundleName: String?
    public var version: String?

    public static func inspect(_ appURL: URL) -> BundleInspector {
        let fm = FileManager.default
        var frameworks: Set<String> = []

        // Frameworks can sit in Contents/Frameworks (Electron, Chromium) or
        // inside a versioned framework's Helpers directory.
        let frameworksDir = appURL.appendingPathComponent("Contents/Frameworks")
        if let entries = try? fm.contentsOfDirectory(atPath: frameworksDir.path) {
            frameworks.formUnion(entries)
        }

        let info = plist(at: appURL.appendingPathComponent("Contents/Info.plist"))

        return BundleInspector(
            frameworks: frameworks,
            sandboxed: isSandboxed(appURL),
            executableName: info?["CFBundleExecutable"] as? String,
            bundleName: info?["CFBundleName"] as? String,
            version: info?["CFBundleShortVersionString"] as? String
        )
    }

    static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// A sandboxed app carries `com.apple.security.app-sandbox` in its
    /// entitlements. `codesign -d --entitlements` is the only reliable way to
    /// read them without private API.
    static func isSandboxed(_ appURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", appURL.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("com.apple.security.app-sandbox")
    }
}
