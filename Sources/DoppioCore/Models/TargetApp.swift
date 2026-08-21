import Foundation

/// An installed application Doppio can make a Shot of.
public struct TargetApp: Identifiable, Hashable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    /// The value of the target's `CFBundleName`. Preserved verbatim in every
    /// wrapper: Electron resolves its helper apps by this name, so renaming it
    /// makes Electron targets fail with "Unable to find helper app".
    public var bundleName: String
    public var executableName: String
    public var path: String
    public var version: String?

    public var url: URL { URL(fileURLWithPath: path) }

    public init(bundleID: String, name: String, bundleName: String,
                executableName: String, path: String, version: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.bundleName = bundleName
        self.executableName = executableName
        self.path = path
        self.version = version
    }
}
