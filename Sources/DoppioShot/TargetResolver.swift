import Foundation
import AppKit

/// Finds the binary a Shot should run, at launch time.
///
/// Resolve-at-launch is what lets a Shot survive the original app being moved
/// or updated: the recorded path is only ever a fallback, and the executable
/// name is re-read from the target's Info.plist rather than cached, because it
/// can change across versions.
enum TargetResolver {
    static func executable(for plan: LaunchPlan, wrapper: URL) -> String? {
        let fm = FileManager.default

        // link and clone Shots must run the binary *inside this wrapper* — that
        // is the whole reason they get their own Dock identity. Recompute the
        // path from the wrapper we are actually running from rather than
        // trusting the recorded one, so a Shot survives being moved or renamed.
        if plan.launchMode == "link" || plan.launchMode == "clone" {
            if let name = plan.targetExecutableName {
                // The target's binary lives in our MacOS/ under its own name.
                let inWrapper = wrapper.appendingPathComponent("Contents/MacOS/\(name)").path
                if fm.isExecutableFile(atPath: inWrapper) { return inWrapper }
            }
            if let path = plan.execPath, fm.isExecutableFile(atPath: path) { return path }
            // Falling through to the original binary would silently drop this
            // Shot's separate identity, so say what happened instead.
            StubLog.note("wrapper executable missing — this Shot will run as the original app; regenerate it in Doppio")
        }

        if let path = plan.execPath, fm.isExecutableFile(atPath: path) {
            return path
        }

        guard let app = locateTargetApp(plan) else { return nil }
        guard let executableName = currentExecutableName(of: app) ?? plan.targetExecutableName else { return nil }
        let candidate = app.appendingPathComponent("Contents/MacOS/\(executableName)").path
        return fm.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    static func locateTargetApp(_ plan: LaunchPlan) -> URL? {
        if let bundleID = plan.targetBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        if let path = plan.targetPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func currentExecutableName(of appURL: URL) -> String? {
        guard let data = try? Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return plist["CFBundleExecutable"] as? String
    }

    /// Shown when the original app has been uninstalled.
    static func reportMissingTarget(_ plan: LaunchPlan) {
        let alert = NSAlert()
        alert.messageText = "The original app for “\(plan.name)” is missing"
        alert.informativeText = """
        This Shot launches \(plan.targetBundleID ?? plan.targetPath ?? "an application") \
        that is no longer installed.

        Reinstall the app, or open Doppio to edit or delete this Shot.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Doppio")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let doppio = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.doppio-mac.Doppio") {
                NSWorkspace.shared.openApplication(at: doppio, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
}
