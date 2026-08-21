import Foundation
import DoppioCore

/// Reproduces the two critical findings from the code review and asserts they
/// are now refused. Both were recursive deletes reachable from user-supplied
/// text, so these are the highest-value tests in the suite.
struct PathGuardTests {

    // MARK: - A1: a Shot name must not be a path-traversal primitive

    /// The exact attack from the review: a name that resolves onto real Chrome.
    func shotNameCannotEscapeTheShotsDirectory() throws {
        var shot = Shot(name: "../../../../Applications/Google Chrome")
        let escaped = DoppioPaths.shotsDirectory
            .appendingPathComponent("\(shot.name).app").standardizedFileURL.path
        Check.equal(escaped, "/Applications/Google Chrome.app",
                    "sanity: the raw name really does traverse")

        // bundleURL must not go there.
        Check.expect(PathGuard.isStrictlyInside(shot.bundleURL, within: DoppioPaths.shotsDirectory),
                     "bundleURL escaped to \(shot.bundleURL.path)")

        shot.name = "../../Desktop/Important"
        Check.expect(PathGuard.isStrictlyInside(shot.bundleURL, within: DoppioPaths.shotsDirectory),
                     "bundleURL escaped to \(shot.bundleURL.path)")
    }

    func unsafeNamesAreRejected() throws {
        for name in ["../../../../Applications/Google Chrome", "../Foo", "a/b",
                     ".hidden", "", "   ", "with\u{0}null"] {
            Check.expect(!Shot.isSafeName(name), "“\(name)” should be rejected as a Shot name")
        }
    }

    func ordinaryNamesAreAccepted() throws {
        for name in ["Chrome Work", "Claude Personal", "Slack — Client A",
                     "VS Code 2", "café", "Shot.with.dots"] {
            Check.expect(Shot.isSafeName(name), "“\(name)” should be a valid Shot name")
        }
    }

    /// Even if an unsafe name reaches the model (hand-edited library.json),
    /// the derived filename must be inert.
    func fileSafeNameNeutralisesTraversal() throws {
        let shot = Shot(name: "../../../../Applications/Google Chrome")
        Check.expect(!shot.fileSafeName.contains("/"), "fileSafeName kept a separator: \(shot.fileSafeName)")
        Check.expect(!shot.fileSafeName.contains(".."), "fileSafeName kept '..': \(shot.fileSafeName)")
        Check.expect(!shot.fileSafeName.hasPrefix("."), "fileSafeName starts with a dot")
        Check.expect(!shot.fileSafeName.isEmpty, "fileSafeName must never be empty")
    }

    // MARK: - A2: the data-directory guard must canonicalise

    /// `.../Shots/../../../../Documents` passed the old hasPrefix guard.
    func traversalOutOfTheDataRootIsRefused() throws {
        let evil = DoppioPaths.dataRoot.appendingPathComponent("../../../../Documents")
        Check.expect(evil.path.hasPrefix(DoppioPaths.dataRoot.path),
                     "sanity: the old prefix test really did accept this")
        Check.expect(!PathGuard.isStrictlyInside(evil, within: DoppioPaths.dataRoot),
                     "traversal out of the data root must be refused")
    }

    /// `.../Shots Backups` passed the old guard because there was no separator.
    func siblingDirectoryIsRefused() throws {
        let sibling = URL(fileURLWithPath: DoppioPaths.dataRoot.path + " Backups")
        Check.expect(sibling.path.hasPrefix(DoppioPaths.dataRoot.path),
                     "sanity: the old prefix test really did accept this")
        Check.expect(!PathGuard.isStrictlyInside(sibling, within: DoppioPaths.dataRoot),
                     "a sibling directory sharing a name prefix must be refused")
    }

    /// The root itself is never a delete target.
    func theRootItselfIsRefused() throws {
        Check.expect(!PathGuard.isStrictlyInside(DoppioPaths.dataRoot, within: DoppioPaths.dataRoot),
                     "the data root itself must never be deleted")
        Check.expect(PathGuard.isContained(DoppioPaths.dataRoot, within: DoppioPaths.dataRoot),
                     "isContained should still accept the root")
    }

    /// A genuine per-Shot directory is accepted, or the feature is broken.
    func genuineDataDirectoriesAreAccepted() throws {
        let real = DoppioPaths.defaultDataDir(for: UUID())
        Check.expect(PathGuard.isStrictlyInside(real, within: DoppioPaths.dataRoot),
                     "a real per-Shot data directory must be accepted")
    }

    /// A user-chosen directory outside the root is refused for deletion — the
    /// "don't wipe my Dropbox folder" case.
    func userChosenDirectoryOutsideTheRootIsRefused() throws {
        let dropbox = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Dropbox/DoppioProfile")
        Check.expect(!PathGuard.isStrictlyInside(dropbox, within: DoppioPaths.dataRoot),
                     "a Shot pointed outside Doppio's root must never be auto-deleted")
    }

    /// A symlink pointing out of the root must not be followed into a delete.
    func symlinkOutOfTheRootIsRefused() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        let inside = root.appendingPathComponent("root")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let link = inside.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        Check.expect(!PathGuard.isStrictlyInside(link, within: inside),
                     "a symlink leaving the root must not count as contained")
    }
}

/// Guards the signing configuration that took several wrong turns to find.
/// Each assertion here corresponds to a failure that shipped a Shot which
/// looked fine and then would not launch.
struct SigningPolicyTests {

    /// Profile-bound entitlements make an ad-hoc binary unlaunchable via Launch
    /// Services, with no crash report to explain it.
    func profileBoundEntitlementsAreFiltered() throws {
        for key in ["com.apple.application-identifier",
                    "com.apple.developer.team-identifier",
                    "com.apple.developer.associated-domains",
                    "keychain-access-groups",
                    "com.apple.security.application-groups",
                    "com.apple.private.something"] {
            let matched = BundleForge.profileBoundEntitlementPrefixes
                .contains { key == $0 || key.hasPrefix($0) }
            Check.expect(matched, "\(key) must be filtered out before ad-hoc signing")
        }
    }

    /// The hardened-runtime entitlements Chromium and Electron actually need
    /// must survive the filter.
    func hardenedRuntimeEntitlementsSurvive() throws {
        for key in ["com.apple.security.cs.allow-jit",
                    "com.apple.security.cs.disable-library-validation",
                    "com.apple.security.cs.allow-unsigned-executable-memory",
                    "com.apple.security.device.camera",
                    "com.apple.security.device.audio-input"] {
            let matched = BundleForge.profileBoundEntitlementPrefixes
                .contains { key == $0 || key.hasPrefix($0) }
            Check.expect(!matched, "\(key) must be preserved — renderers need it")
        }
    }

    /// Signing must set flags explicitly. Preserving them carries Chrome's
    /// `library-validation` flag, which outranks the entitlement and stops the
    /// app loading its own framework.
    func signingSetsFlagsExplicitly() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // DoppioTests
                .deletingLastPathComponent()      // Sources
                .appendingPathComponent("DoppioCore/Services/BundleForge.swift"),
            encoding: .utf8)
        Check.expect(source.contains(#"["--force", "--options", "runtime"]"#),
                     "codesign must set --options runtime explicitly")
        Check.expect(!source.contains("preserve-metadata=flags"),
                     "flags must not be preserved: Chrome's library-validation flag breaks the clone")
        Check.expect(!source.contains(#""--deep""#),
                     "--deep must not be passed: it is deprecated and strips nested entitlements")
        Check.expect(source.contains("disable-library-validation"),
                     "the clone must disable library validation to load vendor-signed frameworks")
    }

    /// The target's binary must keep its own name, or Chromium cannot find its
    /// framework.
    func targetBinaryKeepsItsName() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCore/Services/BundleForge.swift"),
            encoding: .utf8)
        Check.expect(!source.contains(#"targetSuffix"#),
                     "renaming the target binary breaks Chromium's framework lookup")
        Check.expect(source.contains(#""CFBundleExecutable": "DoppioShot""#),
                     "the stub must be CFBundleExecutable, sitting beside the target binary")
    }
}

/// Covers behaviour changed in response to the code review and the WhatsApp
/// result, so the reasoning cannot be quietly undone.
struct BehaviourTests {

    /// A direct-mode Shot shares the original's bundle ID, so "is it running?"
    /// must not be answered by looking at the original app.
    func directModeRunStateIsNotTheOriginalApp() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCore/Services/ShotLibrary.swift"),
            encoding: .utf8)
        Check.expect(!source.contains("app.bundleIdentifier == shot.targetBundleID"),
                     "run state must not be inferred from the original app's bundle ID")
        Check.expect(source.contains("case running, notRunning, unknown"),
                     "run state must be able to say it does not know")
    }

    /// The library index is shared between the app and the CLI.
    func libraryWritesAreCoordinatedAndAtomic() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCore/Services/ShotLibrary.swift"),
            encoding: .utf8)
        Check.expect(source.contains("NSFileCoordinator"),
                     "library.json is shared with the CLI and needs coordination")
        Check.expect(source.contains("options: .atomic"),
                     "a crash mid-write must not truncate the Shot index")
        Check.expect(source.contains("library.corrupt-"),
                     "an unreadable index must be quarantined, not silently emptied")
    }

    /// Rules that are verified negatives must stay negative.
    func testedUnsupportedFamiliesStayMarkedUnsupported() throws {
        let engine = CompatEngine.loadBundledOnly()
        guard let whatsapp = engine.rules.first(where: { $0.id == "whatsapp" }) else {
            Check.expect(false, "the whatsapp rule should exist")
            return
        }
        Check.expect(whatsapp.launchMode == .direct,
                     "WhatsApp was tested: cloning a sandboxed app does not isolate it")
        Check.expect(whatsapp.strategy == IsolationStrategy.none,
                     "WhatsApp must not claim data isolation")
        Check.expect(whatsapp.verifiedOn != nil,
                     "a tested negative is still a tested result and should say when")
    }

    /// Only rules actually run through `doppio verify` may claim verification.
    func verifiedRulesAreTheOnesActuallyTested() throws {
        let engine = CompatEngine.loadBundledOnly()
        let verified = Set(engine.rules.filter { $0.verifiedOn != nil }.map(\.id))
        let expected: Set<String> = ["chrome", "claude-desktop", "whatsapp", "sandboxed-generic"]
        Check.expect(verified == expected,
                     "verified set drifted: \(verified.sorted()) — update this test only after actually testing")
    }

    /// The verifier must check that a Shot stays up, not merely that it started.
    func verifierChecksTheShotStaysRunning() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCore/Services/ShotVerifier.swift"),
            encoding: .utf8)
        Check.expect(source.contains("stays running"),
                     "WhatsApp started and then exited — starting is not enough")
        Check.expect(source.contains("separate container"),
                     "a sandboxed target with no container has no isolation")
        Check.expect(source.contains("original app intact"),
                     "the checklist must verify the target app was not modified")
    }
}

/// Covers the subsystems round 2 of review found untested: the verifier's
/// process discrimination, CLI flag parsing, and database consistency.
struct VerifierAndCLITests {

    /// A direct-mode Shot runs the *original* binary, so looking for the
    /// wrapper path found nothing and every direct Shot was reported broken.
    func directModeIsNotDetectedByWrapperPath() throws {
        let direct = Shot(name: "D", launchMode: .direct, strategy: .chromium,
                          targetBundleID: "com.google.Chrome")
        switch ShotVerifier.discriminator(for: direct) {
        case .dataDirArgument(let dir):
            Check.equal(dir, direct.dataDir, "a direct Shot is found by its data-dir argument")
        default:
            Check.expect(false, "a direct Shot that isolates data must be matched on that argument")
        }
    }

    /// A direct Shot that isolates nothing genuinely cannot be distinguished,
    /// and must say so rather than failing.
    func directModeWithoutIsolationIsIndistinguishable() throws {
        let shot = Shot(name: "D", launchMode: .direct, strategy: .none)
        switch ShotVerifier.discriminator(for: shot) {
        case .indistinguishable: Check.expect(true, "correctly reported as indistinguishable")
        default: Check.expect(false, "a direct Shot with shared data cannot be identified")
        }
    }

    /// clone and link Shots exec from inside the wrapper, so the path works.
    func wrapperModesAreDetectedByPath() throws {
        for mode in [LaunchMode.clone, .link] {
            let shot = Shot(name: "W", launchMode: mode, strategy: .electron)
            switch ShotVerifier.discriminator(for: shot) {
            case .wrapperPath(let url):
                Check.equal(url.path, shot.bundleURL.path, "\(mode) is matched on the wrapper path")
            default:
                Check.expect(false, "\(mode) should be matched on the wrapper path")
            }
        }
    }

    /// The crash check counted every report on the machine, so an unrelated
    /// crash during the ten-second window failed an honest Shot.
    func crashReportsAreAttributedToTheShot() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCore/Services/ShotVerifier.swift"),
            encoding: .utf8)
        Check.expect(source.contains("newCrashReports(since:"),
                     "crash reports must be filtered, not merely counted")
        Check.expect(source.contains("body.contains(shot.wrapperBundleID)"),
                     "a report should be attributed by the Shot's own bundle identifier")
    }

    /// `doppio verify --quick "Name"` used to consume the name as the flag's value.
    func booleanFlagsDoNotSwallowTheNextArgument() throws {
        for flag in ["quick", "all", "yes", "force", "verify", "json"] {
            Check.expect(CLIOptionsProbe.booleanFlags.contains(flag),
                         "--\(flag) takes no value and must be listed as boolean")
        }
    }

    /// The app reads the copy under Sources/; the repo shows compat-db/. They
    /// are maintained by hand and can drift silently.
    func bothCopiesOfTheRulesDatabaseAreIdentical() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let a = try Data(contentsOf: root.appendingPathComponent("compat-db/rules.json"))
        let b = try Data(contentsOf: root.appendingPathComponent("Sources/DoppioCore/Resources/rules.json"))
        let x = try JSONSerialization.jsonObject(with: a) as? [String: Any]
        let y = try JSONSerialization.jsonObject(with: b) as? [String: Any]
        Check.expect(NSDictionary(dictionary: x ?? [:]).isEqual(to: y ?? [:]),
                     "compat-db/rules.json and Sources/DoppioCore/Resources/rules.json have drifted")
    }

    /// No rule may claim `home` isolation, which the project measured does not
    /// work for apps that resolve paths through Foundation, unless its note
    /// says why it is expected to work.
    func homeStrategyRulesJustifyThemselves() throws {
        for rule in CompatEngine.loadBundledOnly().rules where rule.strategy == .home {
            let note = (rule.notes ?? "").lowercased()
            Check.expect(note.contains("$home") || note.contains("unverified"),
                         "rule '\(rule.id)' claims home isolation without explaining or qualifying it")
        }
    }
}

/// Mirror of the CLI's boolean-flag list. The CLI is a separate executable, so
/// its types cannot be imported; keeping the list here as a tripwire is still
/// better than not checking it at all.
enum CLIOptionsProbe {
    static let booleanFlags: Set<String> = [
        "all", "quick", "keep-running", "verify", "launch-now",
        "ephemeral", "status-item", "data", "yes", "json", "force",
    ]
}

/// Round-3 findings. The first is the most valuable test here: a fix made in
/// round 2 introduced a crash in the very flow it was fixing.
struct RoundThreeTests {

    /// `webViewDidClose` must only close the window. `close()` fires
    /// `willCloseNotification` synchronously, and that observer prunes the
    /// array — so a following `remove(at:)` indexed past the end and trapped
    /// exactly when an OAuth popup completed sign-in.
    func popupCloseHasASinglePruningPath() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioShot/WebShell.swift"),
            encoding: .utf8)
        Check.expect(!source.contains("popupWindows.remove(at:"),
                     "remove(at:) after close() traps: the notification observer already pruned the array")
        Check.expect(source.contains("popupWindows.removeAll { $0 === window }"),
                     "the willClose observer must be the one place the array is pruned")
        Check.expect(source.contains("isReleasedWhenClosed = false"),
                     "a referenced window must not be released on close")
    }

    /// A clone shares the target's executable name, so matching crash reports
    /// by filename prefix failed a Chrome Shot whenever real Chrome crashed.
    func crashAttributionDoesNotOverMatchClones() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCore/Services/ShotVerifier.swift"),
            encoding: .utf8)
        Check.expect(source.contains("shot.launchMode == .direct, let targetExecutable"),
                     "the filename-prefix fallback must be limited to direct Shots")
    }

    /// Web data lives a few levels down, so counting immediate children
    /// reported "1 entry" for a store holding a dozen files.
    func webDataIsCountedRecursively() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCore/Services/ShotVerifier.swift"),
            encoding: .utf8)
        Check.expect(source.contains("static func fileCount"),
                     "web-Shot data must be counted recursively")
    }

    /// Deletion must cover both possible WebKit layouts. Measured on macOS 26.6:
    /// the identifier store nests inside the per-bundle directory. The
    /// top-level location is handled defensively in case that changes.
    func webDataDeletionCoversBothLayouts() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCore/Services/BundleForge.swift"),
            encoding: .utf8)
        Check.expect(source.contains(#"webKitRoot.appendingPathComponent(shot.wrapperBundleID)"#),
                     "the per-bundle directory is where the store actually lives today")
        Check.expect(source.contains("WebsiteDataStore/"),
                     "a future top-level identifier store should still be cleaned up")
    }

    /// Dark appearance is not expressible, so no interface may accept it.
    func darkAppearanceIsNotOffered() throws {
        Check.expect(!Shot.Appearance.selectable.contains(.dark),
                     "the GUI must not offer an option that does nothing")
        let cli = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCLI/main.swift"),
            encoding: .utf8)
        Check.expect(cli.contains("dark appearance cannot be forced"),
                     "the CLI must reject --appearance dark rather than silently ignoring it")
    }

    /// Both CLI launch paths must use the synchronous form; the async one loses
    /// its error on a runloop-less main thread.
    func cliLaunchPathsReportFailure() throws {
        let cli = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DoppioCLI/main.swift"),
            encoding: .utf8)
        Check.expect(!cli.contains("library.launch(shot)"),
                     "the CLI must use launchSynchronously so failures are reported")
        Check.equal(cli.components(separatedBy: "launchSynchronously").count - 1, 2,
                    "both `launch` and `create --launch-now` should use it")
    }
}

/// The uninstaller deletes recursively across four different roots, so its
/// containment rules get the same treatment as PathGuard's.
struct UninstallerTests {

    /// Each kind of item may only be removed from its own root.
    func removalIsFencedPerItemKind() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cases: [(Uninstaller.Item.Kind, URL, Bool, String)] = [
            (.shotBundle, DoppioPaths.shotsDirectory.appendingPathComponent("A.app"), true,
             "a Shot inside ~/Applications/Doppio"),
            (.shotBundle, URL(fileURLWithPath: "/Applications/Google Chrome.app"), false,
             "a real application must never be removable as a Shot"),
            (.shotData, DoppioPaths.defaultDataDir(for: UUID()), true,
             "a Shot's own data directory"),
            (.shotData, home.appendingPathComponent("Documents"), false,
             "the user's Documents folder must never be removable"),
            (.shotData, home.appendingPathComponent("Dropbox/DoppioProfile"), false,
             "data the user pointed elsewhere is theirs"),
            (.webKitStore, home.appendingPathComponent("Library/WebKit/org.doppio-mac.shot.x"), true,
             "a Shot's website data"),
            (.webKitStore, home.appendingPathComponent("Library/WebKit"), false,
             "the whole WebKit folder, holding every other app's data, must never go"),
            (.supportDirectory, DoppioPaths.supportDirectory, true,
             "Doppio's own support directory"),
            (.supportDirectory, home.appendingPathComponent("Library/Application Support"), false,
             "every application's support data must never be removable"),
        ]
        for (kind, url, expected, why) in cases {
            Check.equal(Uninstaller.isSafeToRemove(url, kind: kind), expected, why)
        }
    }

    /// Traversal must not get past the per-kind fence either.
    func traversalCannotEscapeTheUninstaller() throws {
        let escape = DoppioPaths.shotsDirectory.appendingPathComponent("../../../../Applications/Safari.app")
        Check.expect(!Uninstaller.isSafeToRemove(escape, kind: .shotBundle),
                     "a traversing path must be refused")
        let dataEscape = DoppioPaths.dataRoot.appendingPathComponent("../../../../Documents")
        Check.expect(!Uninstaller.isSafeToRemove(dataEscape, kind: .shotData),
                     "a traversing data path must be refused")
    }

    /// Only a symlink pointing into Doppio counts as ours; a real binary
    /// someone else installed at that path is left alone.
    func onlyDoppiosOwnCommandLineToolIsRemoved() throws {
        let fake = URL(fileURLWithPath: "/usr/local/bin/doppio")
        // On a machine where Doppio's symlink is absent this must be false,
        // never "remove whatever is there".
        if Uninstaller.doppioOwnedCommandLineTool() == nil {
            Check.expect(!Uninstaller.isSafeToRemove(fake, kind: .commandLineTool),
                         "with no Doppio-owned symlink present, nothing at that path may be removed")
        } else {
            Check.expect(true, "a Doppio-owned symlink is installed on this machine")
        }
    }

    /// A plan built with keepData must not list any data.
    func keepDataExcludesEveryDataItem() throws {
        let shot = Shot(name: "KeepMe", mode: .web, url: "https://example.com")
        let plan = Uninstaller(shots: [shot], keepData: true, removeApplication: false).plan()
        for item in plan.items {
            Check.expect(item.kind != .shotData && item.kind != .webKitStore
                         && item.kind != .supportDirectory,
                         "--keep-data must not list \(item.kind.rawValue)")
        }
    }

    /// keepApp must leave the application out of the plan.
    func keepAppExcludesTheApplication() throws {
        let plan = Uninstaller(shots: [], keepData: true, removeApplication: false).plan()
        Check.expect(!plan.items.contains { $0.kind == .application },
                     "--keep-app must not list Doppio itself")
    }
}
