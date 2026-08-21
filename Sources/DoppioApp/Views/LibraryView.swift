import SwiftUI
import Combine
import DoppioCore

/// The main window: every Shot the user has, with its state, plus the entry
/// point for making new ones.
struct LibraryView: View {
    @EnvironmentObject var library: ShotLibrary
    @State private var selection: Shot.ID?
    @State private var showingCreate = false
    @State private var showingFirstRun = false
    @State private var search = ""
    @State private var pendingDelete: Shot?

    private var filtered: [Shot] {
        guard !search.isEmpty else { return library.shots }
        return library.shots.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selection, let shot = library.shots.first(where: { $0.id == selection }) {
                ShotDetailView(shot: shot)
                    .id(shot.id)
            } else {
                EmptyStateView(showingCreate: $showingCreate)
            }
        }
        .navigationTitle("Doppio")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("New Shot", systemImage: "plus")
                }
                .help("Create a new Shot (⌘N)")
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateShotSheet()
                .environmentObject(library)
        }
        .sheet(isPresented: $showingFirstRun) {
            FirstRunView(dismiss: { showingFirstRun = false })
        }
        .alert("Something went wrong",
               isPresented: Binding(
                   get: { library.lastError != nil },
                   set: { if !$0 { library.lastError = nil } })) {
            Button("OK") { library.lastError = nil }
        } message: {
            Text(library.lastError ?? "")
        }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "DoppioDidShowIntro") {
                showingFirstRun = true
                UserDefaults.standard.set(true, forKey: "DoppioDidShowIntro")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .doppioNewShot)) { _ in
            showingCreate = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .doppioUninstall)) { _ in
            UninstallController.run(library: library)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Shot Only") {
                if let shot = pendingDelete { selection = nil; quitThenDelete(shot, data: false) }
                pendingDelete = nil
            }
            Button("Delete Shot and Its Data", role: .destructive) {
                if let shot = pendingDelete { selection = nil; quitThenDelete(shot, data: true) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The original application is never touched.")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Shots") {
                ForEach(filtered) { shot in
                    ShotRow(shot: shot)
                        .tag(shot.id)
                        .contextMenu { contextMenu(for: shot) }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search Shots")
        .listStyle(.sidebar)
        .frame(minWidth: 240)
        .overlay {
            if library.shots.isEmpty {
                Text("No Shots yet")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    /// A running Shot is asked to quit before being removed, so the guard
    /// cannot leave the user with no way forward.
    private func quitThenDelete(_ shot: Shot, data: Bool) {
        if library.runState(of: shot) == .running, !library.quit(shot) {
            library.lastError = "“\(shot.name)” did not quit, so it has not been deleted."
            return
        }
        library.delete(shot, includingData: data)
    }

    @ViewBuilder
    private func contextMenu(for shot: Shot) -> some View {
        Button("Launch") { library.launch(shot) }
        Button("Show in Finder") { library.reveal(shot) }
        Button("Show Data Folder") { library.revealData(shot) }
        Divider()
        Button("Duplicate") { library.duplicate(shot) }
        Button("Regenerate") {
            if library.runState(of: shot) == .running { library.quit(shot) }
            library.regenerate(shot)
        }
        Divider()
        // Confirm here too: the detail pane asks, so the context menu must not
        // delete on a single click.
        Button("Delete…", role: .destructive) {
            pendingDelete = shot
        }
    }
}

/// One row in the sidebar: icon, name, what it is, and whether it needs
/// attention.
struct ShotRow: View {
    @EnvironmentObject var library: ShotLibrary
    let shot: Shot

    var body: some View {
        HStack(spacing: 10) {
            ShotIcon(shot: shot, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(shot.name).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // Only shown when it is actually known: a direct-mode Shot shares
            // the original's identity, so "running" is often unanswerable.
            switch library.runState(of: shot) {
            case .running:
                Circle().fill(.green).frame(width: 7, height: 7).help("Running")
            case .notRunning, .unknown:
                EmptyView()
            }
            if library.health(of: shot).isProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Needs attention — select for details")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch shot.mode {
        case .web:  return shot.url ?? "Web app"
        case .file: return (shot.documentPath as NSString?)?.lastPathComponent ?? "Document"
        case .app:  return shot.strategy.isolatesData ? "Separate data" : "Shared data"
        }
    }
}

/// Renders the Shot's icon the same way its bundle does, so the sidebar
/// matches the Dock.
struct ShotIcon: View {
    let shot: Shot
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: size, height: size)
    }

    private var image: NSImage {
        // Prefer the generated icon so tint and badge show up.
        let icns = shot.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
        if let existing = NSImage(contentsOf: icns) { return existing }
        let target = AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath)
        return IconFactory.renderedImage(for: shot, target: target)
    }
}

struct EmptyStateView: View {
    @Binding var showingCreate: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Pour a second shot of any app")
                .font(.title2)
            Text("A Shot is a real app in your Dock that runs another\nindependent copy of an app you already have — with its\nown accounts and settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Create a Shot…") { showingCreate = true }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(40)
    }
}

