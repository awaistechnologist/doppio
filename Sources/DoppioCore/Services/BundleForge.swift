import Foundation
import AppKit

public enum ForgeError: LocalizedError {
    case targetNotFound(String)
    case stubMissing
    case notSameVolume(String)
    case signingFailed(String)
    case cloneFailed(String)
    case escapesWrapper(String, String)

    public var errorDescription: String? {
        switch self {
        case .targetNotFound(let s):
            return "Could not find the original application (\(s)). It may have been uninstalled."
        case .stubMissing:
            return "Doppio's launcher stub is missing from the app bundle. Reinstall Doppio."
        case .notSameVolume(let s):
            return "Cloned Shots need the original app on the same disk as ~/Applications. \(s)"
        case .signingFailed(let s):
            return "Code signing the Shot failed: \(s)"
        case .cloneFailed(let s):
            return "Cloning the application failed: \(s)"
        case .escapesWrapper(let name, let resolved):
            return "Refused to write \(name): it resolves to \(resolved), outside the Shot's own bundle. This would have modified another application."
        }
    }
}

/// Creates, edits and signs the wrapper `.app` bundles that are Shots.
///
/// Three launch modes, all verified on macOS 26.6 — see `docs/mechanism.md`:
///
/// - `.link`   symlink farm; the stub execs a symlink *inside* the wrapper so
///             the kernel attributes the process to the wrapper bundle.
/// - `.clone`  APFS copy-on-write clone of the target with a patched
///             Info.plist. Needed by Chromium browsers, whose sandboxed
///             helpers must find the framework under the main bundle's path.
/// - `.direct` the stub execs the target's real binary. Always works, but the
///             instance is attributed to the original app.
public struct BundleForge {
    public let stubURL: URL

    public init(stubURL: URL? = nil) throws {
        if let stubURL {
            self.stubURL = stubURL
        } else {
            guard let found = Self.locateStub() else { throw ForgeError.stubMissing }
            self.stubURL = found
        }
    }

    /// The stub ships inside Doppio.app's Resources; when running from a plain
    /// SwiftPM build it sits next to the executable.
    static func locateStub() -> URL? {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/DoppioShot"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("DoppioShot"),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("DoppioShot"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Creating and editing

    /// Builds the Shot's bundle atomically: everything is assembled at a
    /// temporary path and swapped into place, so a Shot never exists
    /// half-written.
    @discardableResult
    public func build(_ shot: Shot, replacing existingBundle: URL? = nil) throws -> URL {
        try DoppioPaths.ensureDirectories()
        let fm = FileManager.default
        let destination = shot.bundleURL

        let staging = DoppioPaths.supportDirectory
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let wrapper = staging.appendingPathComponent(destination.lastPathComponent)

        switch shot.mode {
        case .app:
            try buildAppWrapper(shot, at: wrapper)
        case .web, .file:
            try buildStandaloneWrapper(shot, at: wrapper)
        }

        // Paths inside shot.json must refer to where the bundle will end up,
        // not the staging directory it is assembled in.
        try writeConfig(shot, into: wrapper, finalURL: destination)
        try sign(wrapper)

        // Swap into place. Editing in place keeps the Dock pin working, so the
        // bundle path must stay stable when only the display name changes.
        //
        // Both the destination and the bundle being replaced are removed or
        // overwritten here, so both must be proven to live in the Shots
        // directory before anything is touched.
        try PathGuard.assertStrictlyInside(destination, within: DoppioPaths.shotsDirectory,
                                           what: "the Shot “\(shot.name)”")
        if let existingBundle, existingBundle != destination,
           PathGuard.isStrictlyInside(existingBundle, within: DoppioPaths.shotsDirectory),
           fm.fileExists(atPath: existingBundle.path) {
            try? fm.removeItem(at: existingBundle)
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: wrapper)
        } else {
            try fm.moveItem(at: wrapper, to: destination)
        }

        try prepareDataDir(shot)
        // Nudge Launch Services so the new identity is registered immediately.
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: destination.deletingLastPathComponent().path)
        return destination
    }

    /// Wrapper for a Shot of an installed application.
    private func buildAppWrapper(_ shot: Shot, at wrapper: URL) throws {
        guard let target = AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath) else {
            throw ForgeError.targetNotFound(shot.targetBundleID ?? shot.targetPath ?? "unknown")
        }

        switch Self.viableLaunchMode(for: shot, target: target) {
        case .clone:
            try cloneTarget(target, to: wrapper)
        case .link:
            try linkFarm(target, to: wrapper)
        case .direct:
            try plainWrapper(at: wrapper)
        }

        try writeInfoPlist(shot, target: target, at: wrapper)
        try installIcon(shot, target: target, at: wrapper)
    }

    /// Wrapper for web / file Shots: no target bundle involved.
    private func buildStandaloneWrapper(_ shot: Shot, at wrapper: URL) throws {
        try plainWrapper(at: wrapper)
        let target = shot.targetBundleID.flatMap {
            AppScanner.resolve(bundleID: $0, fallbackPath: shot.targetPath)
        }
        try writeInfoPlist(shot, target: target, at: wrapper)
        try installIcon(shot, target: target, at: wrapper)
    }

    // MARK: - Launch-mode implementations

    /// Minimal bundle containing just the stub.
    private func plainWrapper(at wrapper: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: wrapper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: wrapper.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: stubURL, to: wrapper.appendingPathComponent("Contents/MacOS/DoppioShot"))
    }

    /// A Shot built in `link` mode for a Chromium or Electron target cannot
    /// start, so silently building one would ship a Shot that crashes on
    /// launch. Upgrade it to `clone`, which is verified to work for both.
    public static func viableLaunchMode(for shot: Shot, target: TargetApp?) -> LaunchMode {
        guard shot.launchMode == .link, shot.mode == .app else { return shot.launchMode }
        if shot.strategy == .chromium || shot.strategy == .electron { return .clone }
        if let target {
            let frameworks = BundleInspector.inspect(target.url).frameworks
            if frameworks.contains(where: { $0.hasSuffix("Framework.framework") }) { return .clone }
        }
        return .link
    }

    /// Symlink farm: mirror the target's `Contents/` with symlinks, then place a
    /// real `MacOS/` holding the stub plus a symlink to the target's binary.
    ///
    /// `Info.plist`, `MacOS` and `_CodeSignature` are deliberately excluded:
    /// we write our own plist, we own `MacOS`, and inheriting the target's
    /// signature directory would make the wrapper unsignable.
    private func linkFarm(_ target: TargetApp, to wrapper: URL) throws {
        let fm = FileManager.default
        let contents = wrapper.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)

        let targetContents = target.url.appendingPathComponent("Contents")
        // Resources is mirrored rather than symlinked: the Shot needs to add its
        // own AppIcon.icns, and writing through a wholesale symlink would put
        // that file inside the original application bundle and break its code
        // signature. Never symlink a directory Doppio intends to write into.
        let excluded: Set<String> = ["Info.plist", "MacOS", "_CodeSignature", "CodeResources", "Resources"]
        for entry in (try? fm.contentsOfDirectory(atPath: targetContents.path)) ?? [] {
            guard !excluded.contains(entry) else { continue }
            try fm.createSymbolicLink(
                at: contents.appendingPathComponent(entry),
                withDestinationURL: targetContents.appendingPathComponent(entry)
            )
        }

        // A real Resources directory whose entries are individually symlinked,
        // so the target's resources are still found but our icon lands here.
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let targetResources = targetContents.appendingPathComponent("Resources")
        for entry in (try? fm.contentsOfDirectory(atPath: targetResources.path)) ?? [] {
            guard entry != "AppIcon.icns" else { continue }
            try? fm.createSymbolicLink(
                at: resources.appendingPathComponent(entry),
                withDestinationURL: targetResources.appendingPathComponent(entry)
            )
        }

        try fm.copyItem(at: stubURL, to: contents.appendingPathComponent("MacOS/DoppioShot"))
        // The real binary, symlinked so nothing is copied, and keeping its own
        // file name — Chromium derives its framework path from the executable's
        // *name*, so renaming it makes Chrome abort in main().
        try fm.createSymbolicLink(
            at: contents.appendingPathComponent("MacOS/\(target.executableName)"),
            withDestinationURL: targetContents.appendingPathComponent("MacOS/\(target.executableName)")
        )
    }

    /// True when a clone of this target would be a free copy-on-write clone.
    ///
    /// `clonefile` only works within one volume. A target on the read-only
    /// system volume (`/System/Applications`, e.g. Terminal.app) still clones
    /// successfully, but as a real byte copy — measured at 3.7 MB -> 7.6 MB for
    /// Terminal. Callers surface this so a multi-gigabyte app does not silently
    /// duplicate itself on disk.
    public static func cloneIsCopyOnWrite(target: TargetApp) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let targetVolume = try? target.url.resourceValues(forKeys: keys).volumeIdentifier
        // The clone is written into the staging directory, not into
        // ~/Applications — so that is the volume that decides whether
        // clonefile can be used.
        let destVolume = try? DoppioPaths.supportDirectory
            .resourceValues(forKeys: keys).volumeIdentifier
        guard let targetVolume, let destVolume else { return true }
        return targetVolume.isEqual(destVolume)
    }

    /// APFS clone of the whole target bundle. `clonefile` makes this instant and
    /// free in disk terms; the bytes are shared until one side is written to.
    private func cloneTarget(_ target: TargetApp, to wrapper: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: wrapper)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        // -c requests a clone and fails loudly if the volume cannot do one,
        // rather than silently falling back to a real 700 MB copy.
        process.arguments = ["-cR", target.path, wrapper.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            // Decide by volume rather than by parsing localized cp output.
            if !Self.cloneIsCopyOnWrite(target: target) {
                throw ForgeError.notSameVolume(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw ForgeError.cloneFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The clone carries the target's signature, which our Info.plist edit
        // invalidates; drop it so the re-sign starts clean. The embedded
        // provisioning profile goes too — it is bound to the vendor's team and
        // cannot match an ad-hoc signature.
        try? fm.removeItem(at: wrapper.appendingPathComponent("Contents/_CodeSignature"))
        try? fm.removeItem(at: wrapper.appendingPathComponent("Contents/embedded.provisionprofile"))

        // Add the stub beside the cloned binary, leaving that binary's name
        // untouched. CFBundleExecutable points at the stub, so Launch Services
        // starts us; the stub then execs the real binary by its original name.
        let stubDest = wrapper.appendingPathComponent("Contents/MacOS/DoppioShot")
        try? fm.removeItem(at: stubDest)
        try fm.copyItem(at: stubURL, to: stubDest)
    }

    // MARK: - Wrapper contents

    private func writeInfoPlist(_ shot: Shot, target: TargetApp?, at wrapper: URL) throws {
        // Start from the target's own Info.plist for app Shots. Modern apps
        // keep launch-critical keys there that cannot be reconstructed:
        // Electron stores ElectronAsarIntegrity (a SHA-256 of app.asar) and
        // refuses to start without it, and Chromium reads its own helper and
        // framework names. Writing a fresh plist silently produced Shots that
        // crashed on launch with "Failed to get integrity for validatable asar
        // archive", so inherit everything and override only identity.
        var inherited: [String: Any] = [:]
        if shot.mode == .app, let target,
           let targetPlist = BundleInspector.plist(at: target.url.appendingPathComponent("Contents/Info.plist")) {
            inherited = targetPlist
            // A Shot must not claim the original's URL schemes or document
            // types: two apps registering the same scheme fight over deep
            // links the user expects their main app to handle.
            inherited.removeValue(forKey: "CFBundleURLTypes")
            inherited.removeValue(forKey: "CFBundleDocumentTypes")
            inherited.removeValue(forKey: "UTExportedTypeDeclarations")
            // An asset-catalog icon would win over the icon we generate.
            inherited.removeValue(forKey: "CFBundleIconName")
            inherited.removeValue(forKey: "CFBundleIcons")
            // The original app owns its own updater.
            inherited.removeValue(forKey: "SUFeedURL")
            inherited.removeValue(forKey: "SUPublicEDKey")
            // Login-item and service registrations belong to the original.
            inherited.removeValue(forKey: "LSMultipleInstancesProhibited")
        }

        var plist: [String: Any] = inherited
        for (key, value) in [
            "CFBundleExecutable": "DoppioShot",
            "CFBundleIdentifier": shot.wrapperBundleID,
            // The user-visible name. Set separately from CFBundleName so
            // renaming a Shot cannot break Electron helper resolution.
            "CFBundleDisplayName": shot.name,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleIconFile": "AppIcon",
            // Provenance, so a Shot is identifiable from its bundle alone.
            "DoppioShotID": shot.id.uuidString,
            "DoppioStubVersion": shot.stubVersion,
        ] as [String: Any] { plist[key] = value }

        // Keep the two version keys distinct: CFBundleVersion is the build
        // number, and the clone-staleness check compares the short string.
        plist["CFBundleShortVersionString"] = target?.version ?? DoppioPaths.appVersion
        if let target,
           let targetPlist = BundleInspector.plist(at: target.url.appendingPathComponent("Contents/Info.plist")),
           let build = targetPlist["CFBundleVersion"] as? String {
            plist["CFBundleVersion"] = build
        } else {
            plist["CFBundleVersion"] = target?.version ?? DoppioPaths.appVersion
        }
        if plist["LSMinimumSystemVersion"] == nil { plist["LSMinimumSystemVersion"] = "13.0" }
        plist["NSHighResolutionCapable"] = true

        // CRITICAL: preserve the target's CFBundleName verbatim. Electron
        // resolves `Contents/Frameworks/<CFBundleName> Helper.app` from it, so
        // changing it makes every Electron target die with
        // "Unable to find helper app".
        if let target, shot.mode == .app {
            plist["CFBundleName"] = target.bundleName
        } else {
            plist["CFBundleName"] = shot.name
        }

        // NSRequiresAquaSystemAppearance can only force *light* appearance;
        // setting it to false is the default and does nothing, so "dark" is not
        // actually expressible this way. Only write the key when it has effect.
        if shot.appearance == .light {
            plist["NSRequiresAquaSystemAppearance"] = true
        }
        if shot.mode == .web {
            // Pinning this to false unconditionally meant an http:// intranet
            // Shot was accepted at creation and then silently refused to load.
            // Grant the exception only for the Shot's own host.
            if shot.needsInsecureHTTP, let host = shot.url.flatMap(URL.init(string:))?.host {
                plist["NSAppTransportSecurity"] = [
                    "NSAllowsArbitraryLoads": false,
                    "NSExceptionDomains": [
                        host: [
                            "NSExceptionAllowsInsecureHTTPLoads": true,
                            "NSIncludesSubdomains": true,
                        ],
                    ],
                ]
            } else {
                plist["NSAppTransportSecurity"] = ["NSAllowsArbitraryLoads": false]
            }
        }

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: wrapper.appendingPathComponent("Contents/Info.plist"))
    }

    private func writeConfig(_ shot: Shot, into wrapper: URL, finalURL: URL) throws {
        let fm = FileManager.default
        let configURL = DoppioPaths.configFile(inWrapper: wrapper)
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let resolved = resolvedLaunchPlan(shot, wrapper: finalURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(resolved).write(to: configURL)
    }

    /// The exact instructions handed to the stub at launch. Resolving this at
    /// generation time keeps the stub tiny and dependency-free.
    public func resolvedLaunchPlan(_ shot: Shot, wrapper: URL) -> LaunchPlan {
        let target = AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath)

        var execPath: String?
        switch (shot.mode, shot.launchMode) {
        case (.app, .link), (.app, .clone):
            // Exec the target's binary *inside our bundle*, under its own name.
            // The path being inside the wrapper is what gives the process the
            // wrapper's Dock identity; the name being unchanged is what lets
            // Chromium and Electron find their frameworks and helpers.
            if let target {
                execPath = wrapper
                    .appendingPathComponent("Contents/MacOS/\(target.executableName)").path
            }
        case (.app, .direct):
            // Runs the original binary in place, so no argv[0] fixup is needed.
            if let target {
                execPath = target.url.appendingPathComponent("Contents/MacOS/\(target.executableName)").path
            }
        default:
            execPath = nil
        }

        let substituted = Substitution(dataDir: shot.dataDir, wrapper: wrapper.path)
        var env = shot.env.mapValues { substituted.apply($0) }
        if shot.homeOverride || shot.strategy == .home {
            env["HOME"] = shot.dataDir
        }

        return LaunchPlan(
            schema: 1,
            shotID: shot.id.uuidString,
            name: shot.name,
            mode: shot.mode.rawValue,
            launchMode: shot.launchMode.rawValue,
            strategy: shot.strategy.rawValue,
            execPath: execPath,
            // Resolve-at-launch fallback: if the recorded exec path is gone the
            // stub re-resolves the target through Launch Services.
            targetBundleID: shot.targetBundleID,
            targetPath: target?.path ?? shot.targetPath,
            targetExecutableName: target?.executableName,
            args: shot.args.map { substituted.apply($0) },
            env: env,
            dataDir: shot.dataDir,
            url: shot.url,
            documentPath: shot.documentPath,
            ephemeral: shot.ephemeral,
            statusItem: shot.statusItem,
            stubVersion: DoppioPaths.stubVersion
        )
    }

    private func prepareDataDir(_ shot: Shot) throws {
        guard shot.strategy != .none || shot.homeOverride || shot.mode == .web else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: shot.dataDirURL, withIntermediateDirectories: true)
        // Firefox shows the profile manager unless the profile directory exists.
        if shot.strategy == .firefox {
            try fm.createDirectory(at: shot.dataDirURL.appendingPathComponent("profile"),
                                   withIntermediateDirectories: true)
        }
    }

    private func installIcon(_ shot: Shot, target: TargetApp?, at wrapper: URL) throws {
        let resources = wrapper.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let destination = resources.appendingPathComponent("AppIcon.icns")

        // The guarantee that Doppio never modifies the original application
        // depends on every write landing inside the wrapper. A symlinked
        // directory in the wrapper would silently redirect this write into the
        // target bundle, so check before touching anything.
        try Self.assertInside(wrapper, destination)

        // In clone mode Resources is the target's own (cloned) copy, which may
        // already hold an icon; replace it so the Shot looks distinct.
        try? FileManager.default.removeItem(at: destination)
        do {
            try IconFactory.writeIcon(for: shot, target: target, to: destination)
        } catch {
            // A Shot showing the original app's icon is far better than one
            // showing a blank tile, and far better than failing to build at
            // all — so carry on. The difference is visible to the user, and the
            // reason goes to the log.
            FileHandle.standardError.write(
                "doppio: \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }

    /// Fails if `path` would resolve outside `wrapper` once symlinks are
    /// followed. This is the invariant that keeps target applications untouched.
    ///
    /// Delegates to `PathGuard` so there is one containment implementation
    /// rather than two with subtly different rules. The parent directory is
    /// what gets checked, because the leaf may not exist yet.
    public static func assertInside(_ wrapper: URL, _ path: URL) throws {
        let parent = path.deletingLastPathComponent()
        guard PathGuard.isContained(parent, within: wrapper) else {
            throw ForgeError.escapesWrapper(path.lastPathComponent, PathGuard.canonical(parent))
        }
    }

    // MARK: - Signing

    /// Ad-hoc signature. Locally generated bundles carry no quarantine flag, so
    /// Gatekeeper accepts them; a Shot copied to another Mac will not pass and
    /// must be regenerated there.
    ///
    /// Three details matter, each learned from a specific failure:
    ///
    /// - Entitlements must be carried over, but **selectively**. Dropping them
    ///   all costs Chromium/Electron renderers `allow-jit` and they degrade or
    ///   crash. Keeping them all is worse: `com.apple.application-identifier`,
    ///   `com.apple.developer.*` and `keychain-access-groups` are restricted
    ///   entitlements that require a real provisioning profile, and an ad-hoc
    ///   binary carrying them is refused by AMFI — the Shot then fails to launch
    ///   from the Dock with no crash report at all, while still running when
    ///   exec'd directly from a terminal. So the target's entitlements are
    ///   filtered to the ones that mean something without a profile.
    /// - The designated requirement is *not* preserved: the vendor's demands
    ///   their certificate chain, which ad-hoc cannot satisfy, and keeping it
    ///   fails verification with "nested code is modified or invalid".
    /// - Code-directory *flags* are set explicitly rather than preserved. The
    ///   `library-validation` flag outranks the disable-library-validation
    ///   entitlement, so preserving Chrome's flags left it unable to load its
    ///   own framework ("different Team IDs") even with the entitlement set.
    /// - `--deep` is *not* used (and is deprecated). In a clone the nested
    ///   helpers are still validly signed by their vendor and we changed only
    ///   the outer Info.plist, so re-sealing the outer bundle alone preserves
    ///   every nested signature and its entitlements.
    public func sign(_ wrapper: URL) throws {
        // A quarantine flag inherited from the target (cp -cR copies xattrs)
        // would make Gatekeeper kill the Shot, so clear it before sealing.
        stripQuarantine(wrapper)

        // Sign inside-out. The parked target binary still carries the vendor's
        // signature, which seals against the *original* Info.plist; since we
        // rewrote that plist, the bundle would fail verification with
        // "invalid Info.plist" unless the parked binary is re-sealed too.
        // Nested helper .app bundles are deliberately left alone: they are
        // independently validated and keep their vendor signature and
        // entitlements.
        for binary in (try? targetBinaries(inside: wrapper)) ?? [] {
            try codesignItem(at: binary)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // Not `try?`: signing with no entitlements produces a clone that
        // launches and then crashes its renderers, which is far worse than a
        // clear failure here.
        var args = ["--force", "--options", "runtime"]
        let wrapperEntitlements = try Self.filteredEntitlementsFile(for: wrapper)
        if let wrapperEntitlements { args += ["--entitlements", wrapperEntitlements.path] }
        defer { if let wrapperEntitlements { try? FileManager.default.removeItem(at: wrapperEntitlements) } }
        args += ["-s", "-", wrapper.path]
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ForgeError.signingFailed(
                (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }


    /// Entitlement keys that require a provisioning profile or a real team
    /// identity. An ad-hoc signature carrying any of these produces a binary
    /// that Launch Services silently refuses to start.
    public static let profileBoundEntitlementPrefixes = [
        // Mac App Store builds use the *bare* key, not a com.apple-prefixed
        // one — missing that left WhatsApp's clone still claiming the original
        // app's identifier.
        "application-identifier",
        "com.apple.application-identifier",
        "aps-environment",
        "com.apple.developer.",
        "com.apple.private.",
        "keychain-access-groups",
        "com.apple.security.application-groups",
    ]

    /// Reads the item's entitlements, drops the profile-bound ones, and writes
    /// the remainder to a temporary plist for `codesign --entitlements`.
    /// Returns nil when the item has no entitlements worth carrying.
    static func filteredEntitlementsFile(for url: URL) throws -> URL? {
        // Even a target with no entitlements needs library validation disabled
        // once we re-sign it ad-hoc beside vendor-signed frameworks.
        let read = Process()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        read.arguments = ["-d", "--entitlements", ":-", url.path]
        let out = Pipe()
        read.standardOutput = out
        read.standardError = FileHandle.nullDevice
        try read.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        read.waitUntilExit()

        let plist = (data.isEmpty ? nil
            : (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any])
            ?? [:]

        var kept = plist.filter { key, _ in
            !profileBoundEntitlementPrefixes.contains { key == $0 || key.hasPrefix($0) }
        }

        // Library validation restricts a process to loading code signed by its
        // own Team ID. Our re-signed binary is ad-hoc (no team) while the
        // frameworks beside it keep the vendor's team, so dyld refuses them:
        //
        //   Library not loaded: @rpath/Electron Framework.framework/...
        //   mapping process and mapped file (non-platform) have different Team IDs
        //
        // Disabling library validation is the entitlement that exists for
        // precisely this case, and it is not profile-bound, so an ad-hoc
        // signature can carry it. The alternative — re-signing every nested
        // component ad-hoc via --deep — makes the team IDs match but strips the
        // helpers' own entitlements (notably allow-jit), which is worse.
        kept["com.apple.security.cs.disable-library-validation"] = true
        guard !kept.isEmpty else { return nil }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppio-entitlements-\(UUID().uuidString).plist")
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: kept, format: .xml, options: 0)
        try encoded.write(to: file)
        return file
    }

    /// The target's own binary inside a wrapper: everything in `MacOS/` that is
    /// not our stub. Symlinks (link mode) are skipped — the file they point at
    /// belongs to the original app and must never be re-signed.
    private func targetBinaries(inside wrapper: URL) throws -> [URL] {
        let fm = FileManager.default
        let macOS = wrapper.appendingPathComponent("Contents/MacOS")
        let entries = try fm.contentsOfDirectory(atPath: macOS.path)
        return entries.compactMap { name -> URL? in
            guard name != "DoppioShot" else { return nil }
            let url = macOS.appendingPathComponent(name)
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            guard (attributes?[.type] as? FileAttributeType) != .typeSymbolicLink else { return nil }
            return url
        }
    }

    /// Ad-hoc signs one item, keeping the entitlements that survive ad-hoc
    /// signing and dropping the profile-bound ones.
    private func codesignItem(at url: URL) throws {
        // Flags are set explicitly, not preserved. Chrome's binary carries the
        // `library-validation` flag in its CodeDirectory, and that flag
        // overrides the disable-library-validation *entitlement* — so
        // preserving it made dlopen of the vendor-signed framework fail with
        // "different Team IDs" no matter what entitlements were present.
        // `runtime` is kept because the hardened runtime is what makes the
        // entitlement meaningful in the first place.
        var args = ["--force", "--options", "runtime"]
        let entitlements = try Self.filteredEntitlementsFile(for: url)
        if let entitlements { args += ["--entitlements", entitlements.path] }
        // The temp plist would otherwise accumulate in /tmp on every build.
        defer { if let entitlements { try? FileManager.default.removeItem(at: entitlements) } }
        args += ["-s", "-", url.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ForgeError.signingFailed("could not sign \(url.lastPathComponent)")
        }
    }

    /// `cp -cR` preserves extended attributes, including
    /// `com.apple.quarantine`. Cloning a target that is still quarantined would
    /// otherwise produce a Shot that Gatekeeper refuses to launch.
    private func stripQuarantine(_ wrapper: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", wrapper.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Removing

    public func delete(_ shot: Shot, includingData: Bool) throws {
        let fm = FileManager.default

        // Both of these are recursive deletes of paths derived from user text,
        // so both have to prove containment first. A prefix test is not enough:
        // see PathGuard.
        let bundle = shot.bundleURL
        try PathGuard.assertStrictlyInside(bundle, within: DoppioPaths.shotsDirectory,
                                           what: "the Shot “\(shot.name)”")
        if fm.fileExists(atPath: bundle.path) {
            try fm.removeItem(at: bundle)
        }

        guard includingData else { return }

        // A web Shot's real storage is WebKit's, keyed by the wrapper's bundle
        // ID — not the declared data directory, which stays empty. Remove both
        // or "delete with data" leaves the logins behind.
        if shot.mode == .web {
            // Measured on macOS 26.6: WKWebsiteDataStore(forIdentifier:) stores
            // under ~/Library/WebKit/<bundle id>/WebsiteDataStore/<uuid>, i.e.
            // *inside* the per-bundle directory, so removing that directory
            // takes the identifier store with it (verified: 14 files removed).
            // The second path is defensive — if a future macOS moves the store
            // to a top-level ~/Library/WebKit/WebsiteDataStore/<uuid>, which
            // does not exist today, deletion still finds it.
            let webKitRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/WebKit")
            let candidates = [
                webKitRoot.appendingPathComponent(shot.wrapperBundleID),
                webKitRoot.appendingPathComponent("WebsiteDataStore/\(shot.id.uuidString.lowercased())"),
                webKitRoot.appendingPathComponent("WebsiteDataStore/\(shot.id.uuidString)"),
            ]
            for candidate in candidates
            where PathGuard.isStrictlyInside(candidate, within: webKitRoot)
                && fm.fileExists(atPath: candidate.path) {
                try? fm.removeItem(at: candidate)
            }
        }

        // Only ever delete inside Doppio's own data root: a user who pointed a
        // Shot at Dropbox or an external disk must not lose that folder.
        guard PathGuard.isStrictlyInside(shot.dataDirURL, within: DoppioPaths.dataRoot) else { return }
        if fm.fileExists(atPath: shot.dataDir) {
            try fm.removeItem(at: shot.dataDirURL)
        }
    }
}

/// `${dataDir}` / `${wrapper}` substitution in rule arguments and env values.
public struct Substitution {
    public let dataDir: String
    public let wrapper: String

    public init(dataDir: String, wrapper: String) {
        self.dataDir = dataDir
        self.wrapper = wrapper
    }

    public func apply(_ value: String) -> String {
        value
            .replacingOccurrences(of: "${dataDir}", with: dataDir)
            .replacingOccurrences(of: "${wrapper}", with: wrapper)
    }
}

/// `shot.json` — the contract between Doppio and the stub.
public struct LaunchPlan: Codable, Sendable {
    public var schema: Int
    public var shotID: String
    public var name: String
    public var mode: String
    public var launchMode: String
    public var strategy: String
    public var execPath: String?
    public var targetBundleID: String?
    public var targetPath: String?
    public var targetExecutableName: String?
    public var args: [String]
    public var env: [String: String]
    public var dataDir: String
    public var url: String?
    public var documentPath: String?
    public var ephemeral: Bool
    public var statusItem: Bool
    public var stubVersion: String

    public init(schema: Int, shotID: String, name: String, mode: String,
                launchMode: String, strategy: String, execPath: String?,
                targetBundleID: String?, targetPath: String?,
                targetExecutableName: String?, args: [String], env: [String: String],
                dataDir: String, url: String?, documentPath: String?,
                ephemeral: Bool, statusItem: Bool, stubVersion: String) {
        self.schema = schema
        self.shotID = shotID
        self.name = name
        self.mode = mode
        self.launchMode = launchMode
        self.strategy = strategy
        self.execPath = execPath
        self.targetBundleID = targetBundleID
        self.targetPath = targetPath
        self.targetExecutableName = targetExecutableName
        self.args = args
        self.env = env
        self.dataDir = dataDir
        self.url = url
        self.documentPath = documentPath
        self.ephemeral = ephemeral
        self.statusItem = statusItem
        self.stubVersion = stubVersion
    }
}
