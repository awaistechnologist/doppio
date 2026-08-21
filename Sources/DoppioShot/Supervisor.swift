import Foundation
import AppKit

/// Runs the target as a child process instead of exec'ing it, so the Shot can
/// do something after the instance quits.
///
/// Only used when a Shot needs it — ephemeral data erasure or a menu-bar item —
/// because it costs an extra live process.
///
/// No `LSUIElement` is needed: the supervisor and the instance it spawns share
/// one bundle, so Launch Services registers them as a single application and
/// only one Dock tile appears. Verified on macOS 26.6.
final class Supervisor: NSObject, NSApplicationDelegate {
    let plan: LaunchPlan
    let executable: String
    private var childPID: pid_t?
    private var statusItem: NSStatusItem?

    init(plan: LaunchPlan, executable: String) {
        self.plan = plan
        self.executable = executable
    }

    func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        app.run()
        exit(EXIT_SUCCESS)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if plan.statusItem { installStatusItem() }
        launchChild()
    }

    /// Spawned with `posix_spawn` rather than `Process` so the child can be
    /// reaped explicitly and the ephemeral erase can run after it exits.
    private func launchChild() {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in plan.env { environment[key] = value }
        if let home = plan.env["HOME"] {
            try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        }

        let argv = [executable] + plan.args
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            for pointer in cArgs where pointer != nil { free(pointer) }
            for pointer in cEnv where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, nil, nil, &cArgs, &cEnv)
        guard status == 0 else {
            StubLog.note("could not start \(executable): \(String(cString: strerror(status)))")
            exit(EXIT_FAILURE)
        }
        childPID = pid

        // Reap on a background thread and hand the result back to the main
        // queue, where the ephemeral erase and teardown run.
        Thread.detachNewThread { [weak self] in
            var info: Int32 = 0
            waitpid(pid, &info, 0)
            DispatchQueue.main.async { self?.childDidExit() }
        }
    }

    private func childDidExit() {
        if plan.ephemeral { eraseDataDirectory() }
        NSApp.terminate(nil)
    }

    /// Erases the Shot's data directory, but only inside Doppio's own data
    /// root: a Shot pointed at Dropbox or an external disk must never be
    /// wiped by this.
    private func eraseDataDirectory() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Doppio/Shots")

        // A plain string prefix is not a containment check: it accepts
        // ".../Shots/../../../../Documents" and it accepts the sibling
        // ".../Shots Backups". Canonicalise, then require a separator boundary.
        // This is a recursive delete — it has to be exactly right.
        let target = URL(fileURLWithPath: plan.dataDir)
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard target != base, target.hasPrefix(base + "/") else {
            StubLog.note("refusing to erase \(plan.dataDir) (resolves to \(target)): outside Doppio's data root")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: plan.dataDir)
            StubLog.note("erased ephemeral data for \(plan.name)")
        } catch {
            StubLog.note("could not erase \(plan.dataDir): \(error)")
        }
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: plan.name)
        item.button?.toolTip = plan.name

        let menu = NSMenu()
        let header = NSMenuItem(title: plan.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if plan.ephemeral {
            let note = NSMenuItem(title: "Data is erased on quit", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show Data Folder",
                                action: #selector(revealData), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(plan.name)",
                                action: #selector(quitShot), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != nil { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plan.dataDir)])
    }

    @objc private func quitShot() {
        // SIGTERM lets the app save state and quit cleanly.
        if let childPID { kill(childPID, SIGTERM) }
    }
}
