import Foundation
import DoppioCore

/// Guards the project's central promise: a Shot never modifies the application
/// it launches.
///
/// This exists because of a real bug. In link mode the wrapper's
/// `Contents/Resources` was a symlink into the target app, so writing the
/// Shot's generated `AppIcon.icns` added a file *inside* the original bundle
/// and broke its code signature. The source-level audit in PrivacyTests could
/// not see it, because the offending call really was in BundleForge.
struct WrapperSafetyTests {

    /// A path inside the wrapper is fine.
    func acceptsPathsInsideTheWrapper() throws {
        let wrapper = URL(fileURLWithPath: "/tmp/doppio-test/Shot.app")
        try BundleForge.assertInside(wrapper, wrapper.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        try BundleForge.assertInside(wrapper, wrapper.appendingPathComponent("Contents/Info.plist"))
        // Assert the predicate directly rather than a tautology.
        Check.expect(PathGuard.isContained(wrapper.appendingPathComponent("Contents/Resources/AppIcon.icns"),
                                           within: wrapper),
                     "a path inside the wrapper must be reported as contained")
    }

    /// A write that resolves out of the wrapper must be refused.
    func rejectsWritesThatEscapeThroughASymlink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("doppio-escape-\(UUID().uuidString)")
        let victim = root.appendingPathComponent("Victim.app/Contents/Resources")
        let wrapper = root.appendingPathComponent("Shot.app")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try fm.createDirectory(at: wrapper.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Exactly the shape of the original bug.
        try fm.createSymbolicLink(
            at: wrapper.appendingPathComponent("Contents/Resources"),
            withDestinationURL: victim)

        let escaping = wrapper.appendingPathComponent("Contents/Resources/AppIcon.icns")
        var refused = false
        do {
            try BundleForge.assertInside(wrapper, escaping)
        } catch {
            refused = true
        }
        Check.expect(refused, "a write redirected into another app bundle must be refused")
    }

    /// A generated wrapper must not contain a symlinked Resources directory,
    /// since that is what allowed the escape.
    func linkModeMirrorsResourcesInsteadOfSymlinkingIt() throws {
        let fm = FileManager.default
        // Inspect any Shot the user actually has; skip cleanly when there are none.
        let shotsDir = DoppioPaths.shotsDirectory
        guard let entries = try? fm.contentsOfDirectory(atPath: shotsDir.path) else { return }
        var checked = 0
        for entry in entries where entry.hasSuffix(".app") {
            let resources = shotsDir.appendingPathComponent(entry)
                .appendingPathComponent("Contents/Resources")
            guard fm.fileExists(atPath: resources.path) else { continue }
            let attributes = try fm.attributesOfItem(atPath: resources.path)
            let isSymlink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
            Check.expect(!isSymlink,
                         "\(entry) has a symlinked Contents/Resources — writes there would hit the original app")
            checked += 1
        }
        // A fresh checkout has no Shots, so this check is advisory; the
        // non-vacuous guarantee is rejectsWritesThatEscapeThroughASymlink.
        if checked == 0 {
            print("      (no installed Shots to inspect)")
        }
    }
}
