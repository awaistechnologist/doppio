import SwiftUI
import DoppioCore

/// The shared editor for a Shot's settings, used both when creating and when
/// editing. Advanced controls stay collapsed so the common path is one field.
struct ShotOptionsForm: View {
    @Binding var shot: Shot
    let target: TargetApp?
    let ruleReason: String

    @State private var showAdvanced = false
    @State private var envText = ""
    @State private var argsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nameAndIcon
            compatibilityNotice
            isolationSection
            warnings
            advanced
        }
    }

    // MARK: - Name and icon

    private var nameAndIcon: some View {
        HStack(alignment: .top, spacing: 12) {
            ShotIcon(shot: shot, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $shot.name)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField("Badge", text: Binding(
                        get: { shot.iconBadge ?? "" },
                        set: { shot.iconBadge = $0.isEmpty ? nil : String($0.prefix(3)) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: shot.iconTint ?? "#FFFFFF") ?? .white) },
                        set: { shot.iconTint = NSColor($0).hexString }))
                        .labelsHidden()
                        .frame(width: 44)
                    Button("No tint") { shot.iconTint = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                    Spacer()
                }
            }
        }
    }

    // MARK: - What the database decided

    @ViewBuilder
    private var compatibilityNotice: some View {
        if !ruleReason.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                Text(ruleReason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var isolationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Dock identity", selection: $shot.launchMode) {
                ForEach(LaunchMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(shot.launchMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Data", selection: $shot.strategy) {
                ForEach(IsolationStrategy.allCases, id: \.self) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Honest warnings

    @ViewBuilder
    private var warnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            if shot.launchMode == .direct {
                warning("This Shot shares the original app's Dock icon and name. It runs a second instance with its own data, but macOS shows both as the same app.")
            }
            if shot.launchMode == .clone {
                warning("Cloning copies the app instantly using copy-on-write, so it uses almost no extra disk space — but the Shot stays on the app's current version. Regenerate it after the original updates.")
            }
            if !shot.strategy.isolatesData && shot.mode == .app {
                warning("This Shot shares data with the original app: same accounts and settings.")
            }
            if shot.launchMode != .direct {
                warning("macOS treats each Shot as a separate app, so you will be asked again for permissions like camera, microphone and files the first time this Shot needs them.")
            }
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Advanced

    private var advanced: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Erase data when the Shot quits", isOn: $shot.ephemeral)
                Toggle("Show a menu bar item while running", isOn: $shot.statusItem)
                Toggle("Override HOME with the data folder", isOn: $shot.homeOverride)

                Picker("Appearance", selection: $shot.appearance) {
                    ForEach(Shot.Appearance.selectable, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                    // A Shot saved earlier may still hold .dark; keep it
                    // selectable so the picker has a matching tag.
                    if shot.appearance == .dark {
                        Text(Shot.Appearance.dark.title).tag(Shot.Appearance.dark)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Data folder").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("", text: $shot.dataDir)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Button("Choose…") { chooseDataDir() }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Arguments (one per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { shot.args.joined(separator: "\n") },
                        set: { shot.args = $0.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 60)
                        .border(.separator)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Environment (KEY=value, one per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { shot.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") },
                        set: { text in
                            var result: [String: String] = [:]
                            for line in text.split(separator: "\n") {
                                guard let equals = line.firstIndex(of: "=") else { continue }
                                result[String(line[line.startIndex..<equals])] = String(line[line.index(after: equals)...])
                            }
                            shot.env = result
                        }))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 60)
                        .border(.separator)
                }
            }
            .padding(.top, 8)
        }
    }

    private func chooseDataDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            let old = shot.dataDir
            shot.dataDir = url.path
            // Keep flags that embedded the old path pointing at the new one.
            shot.args = shot.args.map { $0.replacingOccurrences(of: old, with: url.path) }
            shot.env = shot.env.mapValues { $0.replacingOccurrences(of: old, with: url.path) }
        }
    }
}
