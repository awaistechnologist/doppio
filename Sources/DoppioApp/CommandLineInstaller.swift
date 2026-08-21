import AppKit
import DoppioCore

/// Symlinks the bundled `doppio` binary onto the user's PATH.
///
/// The CLI lives in `Doppio.app/Contents/Resources/doppio` so that deleting
/// Doppio takes it with it. `/usr/local/bin` is the conventional place for it
/// and is user-writable on most Macs; when it is not, the command to run is
/// offered for copying rather than silently failing or asking for a password.
enum CommandLineInstaller {
    static let destination = "/usr/local/bin/doppio"

    static func install() {
        let alert = NSAlert()

        guard let source = Bundle.main.url(forResource: "doppio", withExtension: nil) else {
            alert.messageText = "The command line tool is missing"
            alert.informativeText = "This copy of Doppio does not contain the doppio binary. Rebuild it with scripts/build-app.sh."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let fm = FileManager.default
        let target = URL(fileURLWithPath: destination)
        let parent = target.deletingLastPathComponent()

        do {
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            // A *dangling* symlink — left behind when Doppio was moved or
            // deleted — is invisible to fileExists and to checkResourceIsReachable,
            // because both follow the link. That is the commonest reinstall
            // case, and it made createSymbolicLink fail with "file exists"
            // which was then misreported as a permissions problem. lstat via
            // attributesOfItem does not follow the link.
            if let attributes = try? fm.attributesOfItem(atPath: target.path) {
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    try fm.removeItem(at: target)
                } else {
                    // Never clobber a real file someone else put there.
                    alert.messageText = "Something else is already installed there"
                    alert.informativeText = """
                    \(destination) exists and is not a symlink, so Doppio has not touched it. \
                    Remove or rename it yourself, then try again.
                    """
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
            }
            try fm.createSymbolicLink(at: target, withDestinationURL: source)
            alert.messageText = "Installed"
            alert.informativeText = "You can now run “doppio” in Terminal.\n\n\(destination) → \(source.path)"
            alert.runModal()
        } catch {
            // Most often /usr/local/bin is not writable by this user.
            alert.messageText = "Could not install automatically"
            // mkdir -p is part of the command: on a Mac that has never had
            // /usr/local/bin, ln alone fails.
            let command = "sudo mkdir -p \(parent.path) && sudo ln -sf \"\(source.path)\" \(destination)"
            alert.informativeText = """
            \(parent.path) is not writable by your account, so this needs one command in Terminal:

            \(command)
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}
