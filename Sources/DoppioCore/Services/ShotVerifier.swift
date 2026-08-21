import Foundation
import AppKit

/// One line of a verification report.
public struct VerificationCheck: Sendable {
    public enum Outcome: String, Sendable {
        case passed, failed, skipped
    }
    public var name: String
    public var outcome: Outcome
    public var detail: String

    public init(_ name: String, _ outcome: Outcome, _ detail: String = "") {
        self.name = name
        self.outcome = outcome
        self.detail = detail
    }

    public var symbol: String {
        switch outcome {
        case .passed:  return "✓"
        case .failed:  return "✗"
        case .skipped: return "–"
        }
    }
}

public struct VerificationReport: Sendable {
    public var shotName: String
    public var checks: [VerificationCheck]

    public var failures: [VerificationCheck] { checks.filter { $0.outcome == .failed } }
    public var passed: Bool { failures.isEmpty }
}

/// Runs the compatibility checklist against a Shot automatically.
///
/// Every failure found while building Doppio was caught by hand: launching the
/// Shot, counting helper processes, reading `lsappinfo`, diffing crash reports,
/// re-checking the original app's signature. Each of those is mechanical, and
/// each one caught a Shot that had been reported as successfully created. This
/// turns the checklist into something the CLI and the app can run.
///
/// Static checks are cheap and never launch anything. Runtime checks launch the
/// Shot, wait for it to settle, and quit it again.
public struct ShotVerifier {
    public let library: ShotLibrary

    public init(library: ShotLibrary) {
        self.library = library
    }

    // MARK: - Static

    /// Checks that need no launch. Safe to run on every create.
    @MainActor
    public static func staticChecks(for shot: Shot) -> [VerificationCheck] {
        var checks: [VerificationCheck] = []
        let fm = FileManager.default

        // 1. The bundle exists where the library thinks it does.
        let bundle = shot.bundleURL
        if fm.fileExists(atPath: bundle.path) {
            checks.append(.init("bundle exists", .passed, bundle.path))
        } else {
            checks.append(.init("bundle exists", .failed, "missing: \(bundle.path)"))
            return checks   // nothing else is meaningful
        }

        // 2. Ad-hoc signature verifies. A Shot that fails this may still launch
        //    today and be refused after a macOS update.
        let signature = run("/usr/bin/codesign", ["--verify", "--verbose=1", bundle.path])
        checks.append(signature.status == 0
            ? .init("signature valid", .passed)
            : .init("signature valid", .failed, firstLine(signature.error)))

        // 3. Provenance. Losing this key means the app inside a clone updated
        //    itself and overwrote Doppio's launcher.
        let plist = BundleInspector.plist(at: bundle.appendingPathComponent("Contents/Info.plist"))
        if shot.launchMode == .direct {
            checks.append(.init("Doppio provenance", .skipped, "direct mode"))
        } else if plist?["DoppioShotID"] != nil {
            checks.append(.init("Doppio provenance", .passed))
        } else {
            checks.append(.init("Doppio provenance", .failed,
                                "DoppioShotID missing — the app may have self-updated over the Shot"))
        }

        // 4. The stub is present and executable.
        let stub = bundle.appendingPathComponent("Contents/MacOS/DoppioShot")
        checks.append(fm.isExecutableFile(atPath: stub.path)
            ? .init("launcher present", .passed)
            : .init("launcher present", .failed, "Contents/MacOS/DoppioShot missing"))

        // 5. The launch plan is readable, and points somewhere real.
        let configURL = DoppioPaths.configFile(inWrapper: bundle)
        if let data = try? Data(contentsOf: configURL),
           let plan = try? JSONDecoder().decode(LaunchPlan.self, from: data) {
            if shot.mode == .app {
                if let exec = plan.execPath, fm.isExecutableFile(atPath: exec) {
                    checks.append(.init("launch plan", .passed, URL(fileURLWithPath: exec).lastPathComponent))
                } else {
                    checks.append(.init("launch plan", .failed,
                                        "execPath is missing or not executable: \(plan.execPath ?? "nil")"))
                }
            } else {
                checks.append(.init("launch plan", .passed, plan.mode))
            }
        } else {
            checks.append(.init("launch plan", .failed, "cannot read \(configURL.lastPathComponent)"))
        }

        // 6. THE ONE THAT MATTERS MOST: the original application is untouched.
        //    Doppio wrote into a target bundle once already; this is the check
        //    that would have caught it.
        if shot.mode == .app {
            if let target = AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath) {
                let original = run("/usr/bin/codesign", ["--verify", "--strict", target.path])
                checks.append(original.status == 0
                    ? .init("original app intact", .passed, "\(target.name) \(target.version ?? "")")
                    : .init("original app intact", .failed,
                            "\(target.name): \(firstLine(original.error))"))
            } else {
                checks.append(.init("original app intact", .failed,
                                    "target not installed: \(shot.targetBundleID ?? "unknown")"))
            }
        } else {
            checks.append(.init("original app intact", .skipped, "no target app"))
        }

        // 7. Built by an older Doppio. `doctor` and the library list already
        //    flag this, and verify is meant to be the authoritative answer —
        //    the two disagreeing ("needs attention" here, "all checks passed"
        //    there) is worse than either verdict alone.
        if shot.stubVersion != DoppioPaths.stubVersion {
            checks.append(.init("launcher up to date", .failed,
                                "built with stub \(shot.stubVersion), current is \(DoppioPaths.stubVersion) — regenerate"))
        } else {
            checks.append(.init("launcher up to date", .passed, shot.stubVersion))
        }

        // 8. A cloned Shot pinned to an older version still runs, but silently
        //    lags the app it was made from.
        if shot.launchMode == .clone,
           let target = AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath),
           let shotVersion = plist?["CFBundleShortVersionString"] as? String,
           let targetVersion = target.version {
            checks.append(shotVersion == targetVersion
                ? .init("clone up to date", .passed, shotVersion)
                : .init("clone up to date", .failed,
                        "Shot is \(shotVersion), app is now \(targetVersion) — regenerate"))
        }

        return checks
    }

    // MARK: - Runtime

    /// Launches the Shot, checks that it really runs, then quits it again.
    ///
    /// `settle` is how long to wait for the app to come up and write its
    /// profile. Chromium and Electron need several seconds before their helper
    /// processes exist, and checking too early reports a false failure — which
    /// happened repeatedly by hand.
    @MainActor
    public func runtimeChecks(for shot: Shot, settle: TimeInterval = 8,
                             keepRunning: Bool = false) -> [VerificationCheck] {
        var checks: [VerificationCheck] = []

        let crashesBefore = Self.crashReportNames()
        let wasRunning = library.isRunning(shot)
        let target = AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath)
        let indistinguishable: Bool
        if case .indistinguishable = Self.discriminator(for: shot) { indistinguishable = true }
        else { indistinguishable = false }

        // Launched with /usr/bin/open rather than NSWorkspace: this runs on a
        // synchronous command-line thread, and NSWorkspace's async open needs a
        // live run loop, which blocking here would deny it.
        _ = Self.run("/usr/bin/open", [shot.bundleURL.path])

        // Poll rather than sleeping a fixed time. Chromium and Electron take
        // several seconds to bring their helpers up, and a fixed wait is either
        // too short (false failure) or wastes time on every check.
        var processes: [String] = []
        let deadline = Date().addingTimeInterval(settle)
        repeat {
            processes = Self.processes(for: shot)
            let hasHelpers = processes.contains { $0.lowercased().contains("helper") }
            let needsHelpers = shot.strategy == .chromium || shot.strategy == .electron
            if !processes.isEmpty && (hasHelpers || !needsHelpers) { break }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline

        if indistinguishable {
            // A direct Shot that isolates nothing runs the original binary with
            // no distinguishing argument; there is genuinely nothing to look for.
            checks.append(.init("launches", .skipped,
                                "direct Shot with shared data — its process cannot be told from the original's"))
        } else if processes.isEmpty {
            checks.append(.init("launches", .failed,
                                "nothing running for \(shot.name) after \(Int(settle))s"))
        } else {
            checks.append(.init("launches", .passed, "\(processes.count) process(es)"))
        }

        // 2. Its Dock identity is the wrapper's, not the original app's. This is
        //    the whole point of link and clone modes.
        if shot.launchMode == .direct {
            checks.append(.init("own identity", .skipped, "direct mode shares the original's identity"))
        } else {
            let running = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == shot.wrapperBundleID }
            if let running {
                checks.append(.init("own identity", .passed,
                                    "\(running.localizedName ?? shot.name) — \(shot.wrapperBundleID)"))
            } else {
                checks.append(.init("own identity", .failed,
                                    "no running app with bundle ID \(shot.wrapperBundleID)"))
            }
        }

        // 2b. It is still running a moment later. WhatsApp's clone started,
        //     registered its identity, and then quit — which the first check
        //     alone reported as a pass.
        if indistinguishable {
            checks.append(.init("stays running", .skipped, "cannot be distinguished from the original"))
        } else if processes.isEmpty {
            checks.append(.init("stays running", .skipped, "never started"))
        } else {
            Thread.sleep(forTimeInterval: 3)
            let still = Self.processes(for: shot)
            checks.append(still.isEmpty
                ? .init("stays running", .failed,
                        "started, then exited within seconds — the app probably refuses to run as a copy")
                : .init("stays running", .passed))
            processes = still.isEmpty ? processes : still
        }

        // 2c. A sandboxed target is only isolated if macOS gives the Shot its
        //     own container, keyed to the wrapper's bundle ID. If no container
        //     appears, the Shot shares the original's account and the whole
        //     point is lost — so this is a failure, not a note.
        if shot.mode == .app, shot.launchMode != .direct,
           let target, BundleInspector.inspect(target.url).sandboxed {
            let container = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(shot.wrapperBundleID)")
            checks.append(FileManager.default.fileExists(atPath: container.path)
                ? .init("separate container", .passed, container.lastPathComponent)
                : .init("separate container", .failed,
                        "the target is sandboxed but no container was created — this Shot shares the original's data"))
        }

        // 3. Helper subprocesses. A Chromium or Electron app whose main process
        //    lives but whose renderers die shows a blank or crashing window —
        //    the exact failure that was mistaken for success twice.
        if shot.strategy == .chromium || shot.strategy == .electron {
            let helpers = processes.filter { $0.lowercased().contains("helper") }
            if !helpers.isEmpty {
                checks.append(.init("helper processes", .passed, "\(helpers.count) running"))
            } else if processes.isEmpty {
                checks.append(.init("helper processes", .skipped, "the Shot did not start"))
            } else {
                checks.append(.init("helper processes", .failed,
                                    "main process is up but no helpers — renderers are dying"))
            }
        } else {
            checks.append(.init("helper processes", .skipped, "not a Chromium/Electron app"))
        }

        // 4. Data really landed in the Shot's own directory.
        if shot.mode == .web {
            // WebKit stores by bundle ID, not in the Shot's declared directory.
            // Counted recursively, and across both possible layouts, so the
            // check reflects real content rather than one wrapper folder.
            let webKitRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/WebKit")
            let candidates = [
                webKitRoot.appendingPathComponent(shot.wrapperBundleID),
                webKitRoot.appendingPathComponent("WebsiteDataStore/\(shot.id.uuidString.lowercased())"),
            ]
            let count = candidates.reduce(0) { $0 + Self.fileCount($1) }
            checks.append(count > 0
                ? .init("isolated data", .passed, "\(count) files under ~/Library/WebKit")
                : .init("isolated data", .failed,
                        "nothing written under ~/Library/WebKit for \(shot.wrapperBundleID)"))
        } else if shot.strategy.isolatesData {
            let count = Self.entryCount(shot.dataDirURL)
            checks.append(count > 0
                ? .init("isolated data", .passed, "\(count) entries in the Shot's data folder")
                : .init("isolated data", .failed,
                        "data folder is empty — the isolation flag may be wrong or ignored"))
        } else {
            checks.append(.init("isolated data", .skipped, "this Shot shares the original's data"))
        }

        // 5. Nothing crashed while we were watching.
        let newCrashes = Self.newCrashReports(since: crashesBefore, shot: shot,
                                              targetExecutable: target?.executableName)
        checks.append(newCrashes.isEmpty
            ? .init("no crashes", .passed)
            : .init("no crashes", .failed, newCrashes.joined(separator: ", ")))

        // Leave the machine as we found it.
        if !keepRunning && !wasRunning {
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == shot.wrapperBundleID }
                .forEach { $0.terminate() }
        }

        return checks
    }

    @MainActor
    public func verify(_ shot: Shot, runtime: Bool = true, settle: TimeInterval = 8,
                      keepRunning: Bool = false) -> VerificationReport {
        var checks = Self.staticChecks(for: shot)
        // A structurally broken Shot cannot tell us anything useful at runtime.
        if runtime, !checks.contains(where: { $0.outcome == .failed }) {
            checks += runtimeChecks(for: shot, settle: settle, keepRunning: keepRunning)
        } else if runtime {
            checks.append(.init("runtime checks", .skipped, "skipped: static checks already failed"))
        }
        return VerificationReport(shotName: shot.name, checks: checks)
    }

    // MARK: - Helpers

    /// Files anywhere beneath a directory. WebKit nests its store a couple of
    /// levels down, so counting only immediate children reported "1 entry" for
    /// a store holding a dozen files.
    static func fileCount(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        var count = 0
        for case let item as URL in e {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
        }
        return count
    }

    static func entryCount(_ url: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).count
    }

    /// Command lines of every process running out of a bundle. `ps` is used
    /// rather than NSRunningApplication because helper processes are not
    /// registered applications and would not appear.
    static func processes(forBundleAt bundle: URL) -> [String] {
        let listing = run("/bin/ps", ["-Ao", "command"])
        return listing.output
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(bundle.path) }
    }

    /// How a Shot's own processes can be recognised.
    ///
    /// A `link` or `clone` Shot execs a binary inside its own wrapper, so the
    /// wrapper path identifies it. A `direct` Shot execs the original app's
    /// binary in place, so the wrapper path appears nowhere — matching on it
    /// reported every direct-mode Shot as failing to launch. Those are found by
    /// their data directory instead, and when a direct Shot isolates nothing
    /// there is no way to tell its process from the original's at all.
    public enum Discriminator {
        case wrapperPath(URL)
        case dataDirArgument(String)
        case indistinguishable
    }

    public static func discriminator(for shot: Shot) -> Discriminator {
        guard shot.launchMode == .direct else { return .wrapperPath(shot.bundleURL) }
        return shot.strategy.isolatesData ? .dataDirArgument(shot.dataDir) : .indistinguishable
    }

    static func processes(for shot: Shot) -> [String] {
        switch discriminator(for: shot) {
        case .wrapperPath(let bundle):
            return processes(forBundleAt: bundle)
        case .dataDirArgument(let dataDir):
            let listing = run("/bin/ps", ["-Ao", "command"])
            return listing.output.split(separator: "\n").map(String.init)
                .filter { $0.contains(dataDir) }
        case .indistinguishable:
            return []
        }
    }

    /// New crash reports attributable to *this* Shot.
    ///
    /// Counting every file that appears in DiagnosticReports failed the verify
    /// whenever anything unrelated on the machine crashed during the ~10-second
    /// window. Reports are matched by the Shot's own bundle identifier, which
    /// appears in the report body as the process coalition, or by the target
    /// executable's name, which is the report's filename prefix.
    static func newCrashReports(since known: Set<String>, shot: Shot,
                                targetExecutable: String?) -> [String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let fresh = entries.filter { $0.hasSuffix(".ips") && !known.contains($0) }

        return fresh.filter { name in
            // The report body names the Shot's own bundle identifier (as the
            // process coalition), which is the precise signal for link and
            // clone Shots.
            if let body = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8),
               body.contains(shot.wrapperBundleID) || body.contains(shot.bundleURL.path) {
                return true
            }
            // The filename prefix is the *target's* executable name, which a
            // clone deliberately shares with the original app — so matching on
            // it would fail a Chrome Shot whenever the real Chrome crashed
            // during the verify window. Only a direct Shot, which has no
            // identity of its own to match, falls back to it.
            if shot.launchMode == .direct, let targetExecutable, name.hasPrefix(targetExecutable) {
                return true
            }
            return false
        }
    }

    static func crashReportNames() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(entries.filter { $0.hasSuffix(".ips") })
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", "\(error)") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }
}
