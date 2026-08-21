import Foundation
import AppKit

/// Persistence and lifecycle for the user's Shots.
///
/// The library is a single JSON file. Deleting Doppio leaves the generated
/// Shots working, so the library is an index, never the source of truth for
/// whether a Shot can launch.
@MainActor
public final class ShotLibrary: ObservableObject {
    @Published public private(set) var shots: [Shot] = []
    @Published public var lastError: String?

    public let compat: CompatEngine
    private let forge: BundleForge?

    public init() {
        self.compat = CompatEngine.loadDefault()
        self.forge = try? BundleForge()
        load()
    }

    public var forgeAvailable: Bool { forge != nil }

    // MARK: - Persistence

    /// Reads the index without mutating state, for merge-before-write.
    static func decodeLibrary() -> [Shot]? {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: DoppioPaths.libraryFile, options: [], error: &coordinationError
        ) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Shot].self, from: data)
    }

    public func load() {
        guard let data = try? Data(contentsOf: DoppioPaths.libraryFile) else { shots = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Shot].self, from: data) {
            shots = decoded
            return
        }
        // A truncated or corrupt index must not be silently treated as "no
        // Shots" — the next save would then overwrite it and lose the list for
        // good. Set it aside so it can be recovered, and say so.
        let quarantine = DoppioPaths.supportDirectory
            .appendingPathComponent("library.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: DoppioPaths.libraryFile, to: quarantine)
        shots = []
        lastError = """
        Doppio could not read its Shot list, so it has been set aside at \
        \(quarantine.lastPathComponent) rather than overwritten. Your Shots \
        themselves still work — they are in ~/Applications/Doppio.
        """
    }

    private func persist() {
        mutate { _ in self.shots }
    }

    /// Read-modify-write the index inside **one** coordination transaction.
    ///
    /// The app and the CLI both own this file. Reading and writing in two
    /// separate transactions leaves a window in which the other process can
    /// write between them, so the whole operation happens inside a single
    /// `coordinate(writingItemAt:)` block: `transform` receives whatever is
    /// actually on disk right now and returns what should replace it.
    private func mutate(_ transform: ([Shot]) -> [Shot]) {
        do {
            try DoppioPaths.ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var thrown: Error?
            var result: [Shot] = shots
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: DoppioPaths.libraryFile, options: [], error: &coordinationError
            ) { url in
                let onDisk = (try? Data(contentsOf: url))
                    .flatMap { try? decoder.decode([Shot].self, from: $0) }
                result = transform(onDisk ?? self.shots)
                do {
                    // .atomic so a crash mid-write cannot truncate the index.
                    try encoder.encode(result).write(to: url, options: .atomic)
                } catch {
                    thrown = error
                }
            }
            if let thrown { throw thrown }
            if let coordinationError { throw coordinationError }
            shots = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            lastError = "Could not save the Shot library: \(error.localizedDescription)"
        }
    }

    // MARK: - Suggestions

    /// A Shot pre-filled from the compatibility database for a target app.
    public func suggestedShot(for app: TargetApp) -> (shot: Shot, rule: CompatRule, reason: String) {
        let (rule, reason) = compat.match(for: app)
        let id = UUID()
        let dataDir = DoppioPaths.defaultDataDir(for: id).path
        // ${wrapper} is only knowable at build time, so leave the token intact
        // here instead of substituting an empty string into the stored args.
        let substitution = Substitution(dataDir: dataDir, wrapper: "${wrapper}")

        let shot = Shot(
            id: id,
            name: uniqueName(basedOn: app.name),
            mode: .app,
            launchMode: rule.launchMode,
            strategy: rule.strategy,
            targetBundleID: app.bundleID,
            targetPath: app.path,
            dataDir: dataDir,
            args: rule.extraArgs.map { substitution.apply($0) },
            env: rule.extraEnv.mapValues { substitution.apply($0) }
        )
        return (shot, rule, reason)
    }

    /// "Chrome" -> "Chrome 2" -> "Chrome 3"; also avoids colliding with an
    /// existing bundle on disk.
    public func uniqueName(basedOn base: String) -> String {
        let taken = Set(shots.map(\.name))
        let fm = FileManager.default
        var candidate = "\(base) 2"
        var counter = 2
        while taken.contains(candidate)
            || fm.fileExists(atPath: DoppioPaths.shotsDirectory.appendingPathComponent("\(candidate).app").path) {
            counter += 1
            candidate = "\(base) \(counter)"
        }
        return candidate
    }

    // MARK: - Mutating

    /// Rebuilding or removing a Shot swaps or deletes the bundle a live process
    /// is running from, which can break that instance in confusing ways.
    /// Callers must either stop it first or pass `force`.
    public func isBlockedByRunningInstance(_ shot: Shot, force: Bool) -> String? {
        guard !force, runState(of: shot) == .running else { return nil }
        return """
        “\(shot.name)” is running. Quit it first, or repeat the action with force \
        to change it underneath the running instance.
        """
    }

    @discardableResult
    public func save(_ shot: Shot, force: Bool = false) -> Bool {
        // Only an existing Shot can be running; a brand-new one cannot.
        if shots.contains(where: { $0.id == shot.id }),
           let blocked = isBlockedByRunningInstance(shot, force: force) {
            lastError = blocked
            return false
        }
        guard let forge else {
            lastError = ForgeError.stubMissing.localizedDescription
            return false
        }
        // A name becomes a filename. Reject unsafe ones outright rather than
        // quietly rewriting them, so the user knows what happened.
        guard Shot.isSafeName(shot.name) else {
            lastError = PathGuardError.unsafeName(shot.name).localizedDescription
            return false
        }
        // Two Shots sharing a name would share one bundle, so creating the
        // second would overwrite the first and deleting either would break the
        // other.
        if shots.contains(where: { $0.id != shot.id && $0.fileSafeName == shot.fileSafeName }) {
            lastError = "A Shot called “\(shot.name)” already exists. Pick a different name."
            return false
        }

        // Persist the mode that will actually be built, so the stored record
        // matches the bundle on disk and clone-staleness detection still works.
        var shot = shot
        let target = AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath)
        shot.launchMode = BundleForge.viableLaunchMode(for: shot, target: target)

        do {
            let existing = shots.first { $0.id == shot.id }
            // Renaming moves the bundle, which breaks any Dock pin — the UI
            // warns about this before getting here.
            let previousBundle = existing.map(\.bundleURL)
            try forge.build(shot, replacing: previousBundle)

            // Merged against whatever is on disk, inside one transaction, so a
            // Shot created by the other process is not dropped.
            mutate { onDisk in onDisk.filter { $0.id != shot.id } + [shot] }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func delete(_ shot: Shot, includingData: Bool, force: Bool = false) {
        if let blocked = isBlockedByRunningInstance(shot, force: force) {
            lastError = blocked
            return
        }
        do {
            try forge?.delete(shot, includingData: includingData)
            // Remove by id from what is on disk, not from a possibly stale
            // in-memory copy: persisting the whole local array would drop a
            // Shot the CLI created since this process last read the file.
            mutate { onDisk in onDisk.filter { $0.id != shot.id } }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func duplicate(_ shot: Shot) {
        var copy = shot
        copy.id = UUID()
        copy.name = uniqueName(basedOn: stripTrailingNumber(shot.name))
        copy.dataDir = DoppioPaths.defaultDataDir(for: copy.id).path
        // Re-point any ${dataDir}-derived paths at the new data directory.
        copy.args = shot.args.map { $0.replacingOccurrences(of: shot.dataDir, with: copy.dataDir) }
        copy.env = shot.env.mapValues { $0.replacingOccurrences(of: shot.dataDir, with: copy.dataDir) }
        save(copy)
    }

    private func stripTrailingNumber(_ name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count > 1, Int(parts.last!) != nil {
            return parts.dropLast().joined(separator: " ")
        }
        return name
    }

    /// Asks a running Shot to quit, and waits briefly for it to go.
    ///
    /// Used by the UI so that "this Shot is running" is an obstacle the user can
    /// clear in one click rather than a dead end.
    @discardableResult
    public func quit(_ shot: Shot, timeout: TimeInterval = 5) -> Bool {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == shot.wrapperBundleID }
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runState(of: shot) != .running { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return runState(of: shot) != .running
    }

    public func launch(_ shot: Shot) {
        let url = shot.bundleURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "\(shot.name) is missing from ~/Applications/Doppio. Use Regenerate to rebuild it."
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        // Every Shot is its own application, so a plain open is enough;
        // `createsNewApplicationInstance` additionally covers `direct` Shots,
        // which share the original's bundle identity.
        config.createsNewApplicationInstance = (shot.launchMode == .direct)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            if let error {
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        }
    }

    /// Launches and reports the outcome synchronously.
    ///
    /// `launch(_:)` hands errors to a completion handler that is dispatched
    /// onto the main actor — which never runs in the CLI, because it has no
    /// run loop, so a failed launch was reported as a success. `open(1)` gives
    /// an exit status on the calling thread.
    @discardableResult
    public func launchSynchronously(_ shot: Shot) -> String? {
        guard FileManager.default.fileExists(atPath: shot.bundleURL.path) else {
            return "\(shot.name) is missing from ~/Applications/Doppio. Use Regenerate to rebuild it."
        }
        let result = ShotVerifier.run("/usr/bin/open", [shot.bundleURL.path])
        guard result.status == 0 else {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "open exited \(result.status)" : detail
        }
        return nil
    }

    public func reveal(_ shot: Shot) {
        NSWorkspace.shared.activateFileViewerSelecting([shot.bundleURL])
    }

    public func revealData(_ shot: Shot) {
        try? FileManager.default.createDirectory(at: shot.dataDirURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([shot.dataDirURL])
    }

    /// Rebuilds a Shot's bundle — used after a Doppio update (stub version
    /// drift) or after the target app updated under a cloned Shot.
    public func regenerate(_ shot: Shot, force: Bool = false) {
        var updated = shot
        updated.stubVersion = DoppioPaths.stubVersion
        save(updated, force: force)
    }

    // MARK: - Health

    public enum Health: Equatable {
        case ok
        case bundleMissing
        case targetMissing(String)
        case staleStub
        case staleClone(shotVersion: String, targetVersion: String)
        /// A cloned app self-updated in place and overwrote Doppio's stub and
        /// patched plist, so the Shot is no longer a Shot.
        case selfUpdated

        public var isProblem: Bool { self != .ok }
    }

    public func health(of shot: Shot) -> Health {
        if !FileManager.default.fileExists(atPath: shot.bundleURL.path) {
            return .bundleMissing
        }
        if shot.mode == .app {
            let plist = BundleInspector.plist(at: shot.bundleURL.appendingPathComponent("Contents/Info.plist"))
            // Electron's Squirrel and Chrome's Keystone update in place. If one
            // runs inside a clone it replaces the bundle wholesale, taking the
            // stub and the patched identity with it — the Shot silently becomes
            // a second full install of the original app. The provenance key is
            // the cheapest way to notice.
            if shot.launchMode != .direct, plist?["DoppioShotID"] == nil {
                return .selfUpdated
            }
            guard let target = AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath) else {
                return .targetMissing(shot.targetBundleID ?? shot.targetPath ?? "unknown")
            }
            // A cloned Shot is pinned to the version it was made from; when the
            // original updates, the Shot silently keeps running the old build.
            if shot.launchMode == .clone {
                let shotVersion = plist?["CFBundleShortVersionString"] as? String
                if let shotVersion, let targetVersion = target.version, shotVersion != targetVersion {
                    return .staleClone(shotVersion: shotVersion, targetVersion: targetVersion)
                }
            }
        }
        if shot.stubVersion != DoppioPaths.stubVersion { return .staleStub }
        return .ok
    }

    /// Whether a Shot is running, as far as it can be known.
    ///
    /// A `direct` Shot shares the original app's bundle identifier, so
    /// identity alone cannot distinguish it — the previous implementation
    /// reported *running* whenever the original app happened to be open. When
    /// the Shot passes a distinguishing argument (its own data directory) that
    /// is matched instead; otherwise the answer is honestly unknown.
    public enum RunState: Sendable {
        case running, notRunning, unknown
    }

    public func runState(of shot: Shot) -> RunState {
        if shot.launchMode != .direct {
            let up = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == shot.wrapperBundleID }
            return up ? .running : .notRunning
        }
        // direct mode: look for the Shot's own data directory in a command line.
        guard shot.strategy.isolatesData else { return .unknown }
        let listing = ShotVerifier.run("/bin/ps", ["-Ao", "command"]).output
        return listing.contains(shot.dataDir) ? .running : .notRunning
    }

    public func isRunning(_ shot: Shot) -> Bool {
        runState(of: shot) == .running
    }
}
