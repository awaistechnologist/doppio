import AppKit
import DoppioCore

/// The app-side "Remove Everything…" action.
///
/// Shows exactly what will be deleted, with sizes, before deleting anything —
/// this removes generated apps and their logins, so it must never be a
/// single-click surprise. Anything outside Doppio's own folders (a Shot whose
/// data the user pointed at Dropbox) is listed as left alone.
@MainActor
enum UninstallController {

    static func run(library: ShotLibrary) {
        let uninstaller = Uninstaller(shots: library.shots)
        let plan = uninstaller.plan()

        guard !plan.isEmpty else {
            let empty = NSAlert()
            empty.messageText = "Nothing to remove"
            empty.informativeText = "No Shots, settings or installed copy of Doppio were found."
            empty.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Remove Doppio and everything it created?"

        var detail = """
        This deletes \(plan.items.count) item(s), \(Uninstaller.humanBytes(plan.totalBytes)) in total, \
        including every Shot and the accounts signed in inside them.

        """
        for item in plan.items.prefix(12) {
            let size = item.bytes > 0 ? " (\(Uninstaller.humanBytes(item.bytes)))" : ""
            detail += "\n• \(item.describedAs)\(size)"
        }
        if plan.items.count > 12 {
            detail += "\n• …and \(plan.items.count - 12) more"
        }
        if !plan.skipped.isEmpty {
            detail += "\n\nLeft alone, because it is outside Doppio's own folders:"
            for path in plan.skipped.prefix(5) { detail += "\n• \(path)" }
        }
        detail += "\n\nThe original applications are never touched. This cannot be undone."
        alert.informativeText = detail

        alert.addButton(withTitle: "Remove Everything")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Keep My Data")
        // Make the destructive button not the default, so Return cancels.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        let response = alert.runModal()
        guard response != .alertSecondButtonReturn else { return }

        let keepData = (response == .alertThirdButtonReturn)
        let finalPlan = keepData
            ? Uninstaller(shots: library.shots, keepData: true).plan()
            : plan

        // Quit anything running, or it would be deleted from under itself.
        for shot in library.shots where library.runState(of: shot) == .running {
            library.quit(shot)
        }

        let failures = Uninstaller(shots: library.shots, keepData: keepData)
            .removeEverything(finalPlan)

        let result = NSAlert()
        if failures.isEmpty {
            result.messageText = "Doppio has been removed"
            result.informativeText = keepData
                ? "Your Shot data was kept. Doppio will now quit."
                : "Everything has been deleted. Doppio will now quit."
            result.runModal()
            NSApp.terminate(nil)
        } else {
            result.alertStyle = .warning
            result.messageText = "Some items could not be removed"
            result.informativeText = failures.prefix(8).joined(separator: "\n")
            result.runModal()
        }
    }
}
