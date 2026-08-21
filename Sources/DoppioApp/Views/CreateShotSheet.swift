import SwiftUI
import DoppioCore

/// Creating a Shot: pick what to pour, confirm how it will be isolated, go.
///
/// The compatibility engine's decision is shown rather than hidden, because the
/// trade-offs (own Dock icon vs. surviving app updates) are real and the user
/// is the one who should pick when they conflict.
struct CreateShotSheet: View {
    @EnvironmentObject var library: ShotLibrary
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable {
        case app = "Application"
        case web = "Website"
        case file = "Document"
    }

    @State private var kind: Kind = .app
    @State private var apps: [TargetApp] = []
    @State private var search = ""
    @State private var selectedApp: TargetApp?
    @State private var shot: Shot?
    @State private var ruleReason = ""
    @State private var urlText = ""
    @State private var webName = ""
    @State private var documentPath: String?
    @State private var openerBundleID: String?
    @State private var busy = false
    /// Shown in the sheet's footer. An alert presented by the parent window is
    /// hidden behind this sheet, so failures looked like nothing happening.
    @State private var errorMessage: String?

    private var filteredApps: [TargetApp] {
        guard !search.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        .task {
            if apps.isEmpty { apps = AppScanner().scan() }
        }
    }

    private var header: some View {
        HStack {
            Text("New Shot").font(.headline)
            Spacer()
            Picker("", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .app:  appPicker
        case .web:  webForm
        case .file: fileForm
        }
    }

    // MARK: - Application

    private var appPicker: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search applications", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(filteredApps, selection: Binding(
                    get: { selectedApp?.bundleID },
                    set: { newValue in
                        guard let newValue, let app = apps.first(where: { $0.bundleID == newValue }) else { return }
                        select(app)
                    })) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: icon(for: app)).resizable().frame(width: 20, height: 20)
                        Text(app.name).lineLimit(1)
                    }
                    .tag(app.bundleID)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 260)

            Group {
                if let shot, let selectedApp {
                    ScrollView {
                        ShotOptionsForm(
                            shot: Binding(
                                get: { shot },
                                set: { self.shot = $0 }),
                            target: selectedApp,
                            ruleReason: ruleReason)
                        .padding(14)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.left")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                        Text("Choose an application")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
    }

    private func icon(for app: TargetApp) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 20, height: 20)
        return image
    }

    private func select(_ app: TargetApp) {
        selectedApp = app
        let suggestion = library.suggestedShot(for: app)
        shot = suggestion.shot
        ruleReason = suggestion.reason
    }

    // MARK: - Website

    private var webForm: some View {
        Form {
            Section {
                TextField("Address", text: $urlText, prompt: Text("https://example.com"))
                TextField("Name", text: $webName, prompt: Text("Example"))
            } footer: {
                Text("A website Shot is a real app in your Dock using the system WebKit engine — no bundled browser. Each web Shot keeps its own cookies and logins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Document

    private var fileForm: some View {
        Form {
            Section {
                HStack {
                    Text(documentPath ?? "No document chosen")
                        .foregroundStyle(documentPath == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseDocument() }
                }
                Picker("Open with", selection: Binding(
                    get: { openerBundleID ?? "" },
                    set: { openerBundleID = $0.isEmpty ? nil : $0 })) {
                    Text("Default application").tag("")
                    ForEach(apps) { app in Text(app.name).tag(app.bundleID) }
                }
                TextField("Name", text: $webName, prompt: Text("Shot name"))
            } footer: {
                Text("A document Shot puts a single file in your Dock, opened by the app you choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            documentPath = url.path
            if webName.isEmpty { webName = url.deletingPathExtension().lastPathComponent }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if kind == .app, let shot {
                Label(shot.launchMode.title, systemImage: shot.launchMode.hasOwnIdentity ? "app.badge.checkmark" : "app.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            if busy { ProgressView().controlSize(.small) }
            Button(busy ? "Creating…" : "Create Shot") { Task { await create() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || busy)
        }
        .padding(12)
    }

    private var canCreate: Bool {
        switch kind {
        case .app:  return shot != nil
        case .web:  return Shot.normalisedWebURL(urlText) != nil && !webName.isEmpty
        case .file: return documentPath != nil && !webName.isEmpty
        }
    }

    /// Cloning a large app takes a second or two and codesign longer, so the
    /// build runs off the main thread. Doing it inline meant the spinner could
    /// never draw, the window froze, and `busy` guarded nothing because no
    /// second click could be delivered while the main thread was blocked.
    private func create() async {
        busy = true
        defer { busy = false }

        let candidate: Shot
        switch kind {
        case .app:
            guard let shot else { return }
            candidate = shot
        case .web:
            guard let url = Shot.normalisedWebURL(urlText) else {
                errorMessage = "“\(urlText)” is not a usable web address. Use an http or https address."
                return
            }
            candidate = Shot(name: webName, mode: .web, launchMode: .link,
                             strategy: .none, url: url.absoluteString)
        case .file:
            guard let documentPath else { return }
            candidate = Shot(name: webName, mode: .file, launchMode: .link,
                             strategy: .none, targetBundleID: openerBundleID,
                             documentPath: documentPath)
        }

        // Hop off the main actor for the filesystem work, then come back.
        let saved = await Task.detached { @MainActor in library.save(candidate) }.value
        if saved {
            dismiss()
        } else {
            // Keep the sheet open and say why, rather than dismissing into an
            // alert the sheet was covering.
            errorMessage = library.lastError ?? "Could not create this Shot."
            library.lastError = nil
        }
    }
}
