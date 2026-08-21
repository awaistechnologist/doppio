import SwiftUI
import DoppioCore

/// Detail pane: run the Shot, see its health, edit and re-generate it.
struct ShotDetailView: View {
    @EnvironmentObject var library: ShotLibrary
    @State var shot: Shot
    @State private var dirty = false
    @State private var confirmingDelete = false
    @State private var deleteData = false
    @State private var originalName: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                actions
                healthBanner
                ShotOptionsForm(shot: $shot, target: resolvedTarget, ruleReason: "")
                    .onChange(of: shot) { _ in dirty = true }
                details
            }
            .padding(18)
        }
        .navigationTitle(shot.name)
        .onAppear { originalName = shot.name }
        // Regenerate/duplicate from the sidebar's context menu mutates the
        // library behind this view; re-read when that happens, unless the user
        // has unsaved edits in the form.
        .onChange(of: library.shots) { shots in
            guard !dirty, let refreshed = shots.first(where: { $0.id == shot.id }) else { return }
            if refreshed != shot { shot = refreshed; originalName = refreshed.name }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save Changes") { save() }
                    .disabled(!dirty)
            }
        }
        .confirmationDialog("Delete “\(shot.name)”?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Shot Only") { deleteShot(includingData: false) }
            Button("Delete Shot and Its Data", role: .destructive) {
                deleteShot(includingData: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(library.runState(of: shot) == .running
                 ? "This Shot is running and will be asked to quit first. The original application is never touched."
                 : "The original application is never touched.")
        }
    }

    private var resolvedTarget: TargetApp? {
        AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                library.launch(shot)
            } label: {
                Label(library.runState(of: shot) == .running ? "Running" : "Launch",
                      systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button("Show in Finder") { library.reveal(shot) }
            Button("Data Folder") { library.revealData(shot) }
            Button("Duplicate") { library.duplicate(shot) }
            Spacer()
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
    }

    @ViewBuilder
    private var healthBanner: some View {
        let health = library.health(of: shot)
        if health.isProblem {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(message(for: health)).fixedSize(horizontal: false, vertical: true)
                    if case .targetMissing = health {} else {
                        Button("Regenerate this Shot") {
                            // Regenerate the *saved* Shot, not the edited copy
                            // in this form: rebuilding should not quietly
                            // commit changes the user has not saved.
                            let stored = library.shots.first(where: { $0.id == shot.id }) ?? shot
                            // Rebuilding swaps the bundle, so stop the instance
                            // running from it first.
                            if library.runState(of: stored) == .running { library.quit(stored) }
                            library.regenerate(stored)
                            // Re-read afterwards, or the pane keeps showing the
                            // old stub version and stale health.
                            if let refreshed = library.shots.first(where: { $0.id == shot.id }), !dirty {
                                shot = refreshed
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func message(for health: ShotLibrary.Health) -> String {
        switch health {
        case .ok:
            return ""
        case .bundleMissing:
            return "This Shot's app bundle is missing from ~/Applications/Doppio."
        case .targetMissing(let id):
            return "The original application (\(id)) is not installed any more. Reinstall it, or delete this Shot."
        case .staleStub:
            return "This Shot was built by an older version of Doppio."
        case .staleClone(let shotVersion, let targetVersion):
            return "This Shot is a clone of version \(shotVersion), but the installed app is now version \(targetVersion). Regenerate it to catch up."
        case .selfUpdated:
            return "This Shot no longer looks like a Shot — the app inside it probably updated itself and overwrote Doppio's launcher. Regenerate it to restore its separate identity and data."
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 4)
            row("Bundle", shot.bundleURL.path)
            row("Bundle ID", shot.wrapperBundleID)
            if let target = resolvedTarget {
                row("Original", "\(target.name) \(target.version ?? "") — \(target.path)")
            }
            if let url = shot.url { row("Address", url) }
            row("Data", shot.dataDir)
            row("Created", shot.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Quits the Shot first if it is running, so deleting is never a dead end.
    /// Without this the guard simply refused and the user had no way forward
    /// from inside the app.
    private func deleteShot(includingData: Bool) {
        if library.runState(of: shot) == .running, !library.quit(shot) {
            library.lastError = """
            “\(shot.name)” did not quit, so it has not been deleted. \
            Quit it yourself and try again.
            """
            return
        }
        library.delete(shot, includingData: includingData)
    }

    private func save() {
        // Renaming moves the bundle, which drops any Dock pin. Warn rather than
        // silently breaking it.
        if shot.name != originalName {
            let alert = NSAlert()
            alert.messageText = "Renaming moves this Shot's app"
            alert.informativeText = "If “\(originalName)” is pinned to your Dock you will need to pin it again after renaming."
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if library.save(shot) {
            dirty = false
            originalName = shot.name
        }
    }
}

struct FirstRunView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 44))
            Text("Welcome to Doppio").font(.title.bold())
            Text("""
            macOS normally lets you run only one copy of an app. Doppio makes \
            **Shots** — real apps in your Dock that each run their own \
            independent copy, with their own accounts and settings.
            """)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                bullet("Your original apps are never modified.")
                bullet("Nothing runs in the background, and there is no telemetry.")
                bullet("Each Shot asks for its own permissions the first time it needs them — that is macOS treating it as its own app.")
            }
            .padding(.vertical, 4)

            Button("Get Started") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 480)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
