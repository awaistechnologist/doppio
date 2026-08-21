import Foundation
import AppKit

// The stub embedded in every Shot. Reads its own shot.json and becomes the
// thing the user asked for: another instance of an app, a web app, or a
// document launcher.

let plan: LaunchPlan
let wrapper: URL
do {
    (plan, wrapper) = try LaunchPlan.load()
} catch {
    // Without a plan there is nothing sensible to run, and the user launched
    // this from the Dock, so say so visibly rather than exiting silently.
    let alert = NSAlert()
    alert.messageText = "This Shot is damaged"
    alert.informativeText = "Doppio could not read its configuration. Open Doppio and regenerate this Shot.\n\n\(error.localizedDescription)"
    alert.alertStyle = .critical
    alert.runModal()
    exit(EXIT_FAILURE)
}

switch plan.mode {
case "web":
    // No HOME override here. It looks like it should redirect WebKit's storage
    // and does nothing: NSHomeDirectory() ignores $HOME (measured — see
    // docs/mechanism.md), so WebKit resolves the real home regardless. Storage
    // is keyed explicitly in WebShell.dataStore() instead.
    WebShell(plan: plan).run()

case "file":
    // Open a specific document with a specific app, as its own Dock icon.
    guard let documentPath = plan.documentPath else {
        // Launched from the Dock, so stderr goes nowhere the user will look.
        StubLog.note("file Shot has no document path")
        let alert = NSAlert()
        alert.messageText = "“\(plan.name)” has no document"
        alert.informativeText = "This Shot is damaged. Open Doppio and regenerate or delete it."
        alert.alertStyle = .warning
        alert.runModal()
        exit(EXIT_FAILURE)
    }
    let document = URL(fileURLWithPath: documentPath)
    if let appURL = TargetResolver.locateTargetApp(plan) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([document], withApplicationAt: appURL,
                                configuration: configuration) { _, _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 20)
    } else {
        NSWorkspace.shared.open(document)
    }
    exit(EXIT_SUCCESS)

default:
    guard let executable = TargetResolver.executable(for: plan, wrapper: wrapper) else {
        TargetResolver.reportMissingTarget(plan)
        exit(EXIT_FAILURE)
    }

    // Supervising costs a live process, so only do it when the Shot needs
    // something to happen after the instance quits.
    if plan.ephemeral || plan.statusItem {
        Supervisor(plan: plan, executable: executable).run()
    } else {
        ExecLauncher.run(plan: plan, executable: executable)
    }
}
