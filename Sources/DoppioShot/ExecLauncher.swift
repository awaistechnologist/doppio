import Foundation
import AppKit

/// Replaces the stub process with the target application.
///
/// `execve` (rather than spawning a child) is what makes a Shot feel like a
/// real app: there is no supervising process left behind, the Dock tile belongs
/// to the running instance, and quitting it leaves nothing running.
enum ExecLauncher {
    static func run(plan: LaunchPlan, executable: String) -> Never {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in plan.env { environment[key] = value }

        // A HOME override needs the directory to exist, or apps that expect
        // ~/Library to be writable fail in confusing ways.
        if let home = plan.env["HOME"] {
            try? FileManager.default.createDirectory(
                atPath: home, withIntermediateDirectories: true)
        }

        // argv[0] is the executable's own path inside the wrapper. It must not
        // be rewritten: Chromium and Electron both locate their frameworks and
        // helpers relative to the running executable.
        let argv = [executable] + plan.args
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)

        execve(executable, &cArgs, &cEnv)

        // execve only returns on failure. The user launched this from the Dock,
        // so show something visible rather than dying silently — every other
        // stub failure path already does.
        let reason = String(cString: strerror(errno))
        StubLog.note("exec failed for \(executable): \(reason)")
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(plan.name)\u{201D} could not start"
        alert.informativeText = "Doppio could not launch the application this Shot points at.\n\n"
            + executable + "\n" + reason
            + "\n\nOpen Doppio and regenerate this Shot."
        alert.alertStyle = .critical
        alert.runModal()
        exit(EXIT_FAILURE)
    }
}
