import Foundation
import DoppioCore

/// Enforces the privacy promise in the spec (§7): Doppio makes no network
/// calls, runs no daemons, and never touches the target app.
///
/// This is a source-level audit rather than a runtime check, because the
/// guarantee is "there is no such code at all".
struct PrivacyTests {
    /// Walks up from this file to the package root so the test works from any
    /// working directory.
    static var sourceRoot: URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.appendingPathComponent("Sources")
            }
        }
        return nil
    }

    /// The shipped product targets. DoppioTests is excluded on purpose: this
    /// file names every forbidden symbol, so auditing it would always fail.
    static let auditedTargets = ["DoppioCore", "DoppioShot", "DoppioApp", "DoppioCLI"]

    func swiftFiles() throws -> [URL] {
        let root = try Check.require(Self.sourceRoot, "could not locate Sources/")
        var files: [URL] = []
        for target in Self.auditedTargets {
            let dir = root.appendingPathComponent(target)
            let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "swift" { files.append(url) }
            }
        }
        Check.expect(!(files.isEmpty), "!(files.isEmpty)")
        return files
    }

    /// No networking APIs anywhere. The one sanctioned exception in the spec is
    /// a user-initiated favicon fetch, which is not implemented — so today the
    /// rule is absolute, and this test is what keeps it that way.
    func noNetworkingAPIs() throws {
        let forbidden = ["URLSession", "NSURLConnection", "CFSocket", "Network.framework",
                         "import Network", "getaddrinfo", "URLRequest(url: URL(string: \"http"]
        for file in try swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for needle in forbidden {
                // WebShell loads the user's own URL in a WKWebView — that is the
                // user browsing, not Doppio phoning home. Exempt only the
                // specific call that does it, not the whole file, so a real
                // URLSession appearing there would still fail this test.
                if file.lastPathComponent == "WebShell.swift",
                   needle == "URLRequest(url: URL(string: \"http" {
                    continue
                }
                Check.expect(!(source.contains(needle)), "\(file.lastPathComponent) uses \(needle): Doppio must make no network calls")
            }
        }
    }

    /// No background agents, daemons or login items.
    func noPersistentBackgroundMechanisms() throws {
        let forbidden = ["SMLoginItemSetEnabled", "launchctl", "LaunchAgents",
                         "LaunchDaemons", "SMAppService"]
        for file in try swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for needle in forbidden {
                Check.expect(!(source.contains(needle)), "\(file.lastPathComponent) references \(needle): Doppio installs nothing persistent")
            }
        }
    }

    /// The target application must never be modified. Only a fixed set of
    /// destructive calls is allowed, and only in the two places that manage
    /// Doppio's own files.
    func noWritesToTargetApplications() throws {
        // IconFactory only ever removes the temporary .iconset it just made.
        // CommandLineInstaller only replaces its own stale /usr/local/bin
        // symlink; it never touches an application bundle.
        // Each of these writes only inside a path Doppio owns:
        //   BundleForge      — the wrapper it is building, guarded by PathGuard
        //   ShotLibrary      — library.json
        //   Supervisor       — the ephemeral data dir, fenced to the data root
        //   IconFactory      — its own temporary .iconset
        //   CommandLineInstaller — its own /usr/local/bin symlink
        //   DoppioPaths      — Doppio's three directories under ~
        //   ExecLauncher     — the HOME override directory for a home-strategy Shot
        let allowed: Set<String> = ["BundleForge.swift", "ShotLibrary.swift",
                                    "Supervisor.swift", "IconFactory.swift",
                                    "CommandLineInstaller.swift", "DoppioPaths.swift",
                                    "ExecLauncher.swift",
                                    //   Uninstaller — removal is its purpose; every path is
                                    //   re-proven with PathGuard immediately before deletion
                                    "Uninstaller.swift"]
        for file in try swiftFiles() where !allowed.contains(file.lastPathComponent) {
            let source = try String(contentsOf: file, encoding: .utf8)
            // copyItem / createDirectory / Data.write are included because the
            // incident this test exists for was an icon *write* through a
            // symlink, not a delete.
            for needle in ["removeItem", "replaceItemAt", "moveItem",
                           "copyItem", "createDirectory", ".write(to:"] {
                Check.expect(!(source.contains(needle)), "\(file.lastPathComponent) mutates the filesystem; keep that in BundleForge")
            }
        }
    }

    /// No private API use.
    func noPrivateAPIs() throws {
        for file in try swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            Check.expect(!(source.contains("dlsym(")), "\(file.lastPathComponent) resolves symbols dynamically")
            Check.expect(!(source.contains("@_silgen_name")), "\(file.lastPathComponent) binds to a private symbol")
        }
    }

    /// Ephemeral erasure is the one destructive act a Shot performs on its own.
    /// It must be fenced to Doppio's data root.
    func ephemeralEraseIsFenced() throws {
        let root = try Check.require(Self.sourceRoot, "Self.sourceRoot")
        let supervisor = root.appendingPathComponent("DoppioShot/Supervisor.swift")
        let source = try String(contentsOf: supervisor, encoding: .utf8)
        // The guard must canonicalise before comparing: a bare string prefix
        // accepts both "…/Shots/../../.." traversal and a "…/Shots Backups"
        // sibling. Assert the properties, not one spelling.
        Check.expect(source.contains("resolvingSymlinksInPath"),
                     "the ephemeral erase must canonicalise the path before comparing")
        Check.expect(source.contains(#"hasPrefix(base + "/")"#),
                     "the ephemeral erase must require a separator boundary")
        Check.expect(source.contains("target != base"),
                     "the ephemeral erase must refuse the data root itself")
        Check.expect(source.contains("refusing to erase"), "the guard should say why it refused")
    }
}
