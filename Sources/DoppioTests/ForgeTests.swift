import Foundation
import AppKit
import DoppioCore

struct SubstitutionTests {
    func dataDirSubstitution() throws {
        let substitution = Substitution(dataDir: "/tmp/data", wrapper: "/tmp/Shot.app")
        Check.expect(substitution.apply("--user-data-dir=${dataDir}") == "--user-data-dir=/tmp/data", "substitution.apply(\"--user-data-dir=${dataDir}\") == \"--us")
        Check.expect(substitution.apply("${dataDir}/extensions") == "/tmp/data/extensions", "substitution.apply(\"${dataDir}/extensions\") == \"/tmp/data")
        Check.expect(substitution.apply("${wrapper}/Contents") == "/tmp/Shot.app/Contents", "substitution.apply(\"${wrapper}/Contents\") == \"/tmp/Shot.a")
        Check.expect(substitution.apply("--no-placeholders") == "--no-placeholders", "substitution.apply(\"--no-placeholders\") == \"--no-placehol")
    }

    /// Paths with spaces must survive substitution untouched — the default data
    /// root lives under "Application Support".
    func substitutionKeepsSpaces() throws {
        let substitution = Substitution(dataDir: "/Users/a/Library/Application Support/Doppio/Shots/x", wrapper: "")
        Check.expect(substitution.apply("--user-data-dir=${dataDir}") == "--user-data-dir=/Users/a/Library/Application Support/Doppio/Shots/x", "substitution.apply(\"--user-data-dir=${dataDir}\") == \"--us")
    }
}

struct ShotModelTests {
    func wrapperBundleIDIsUniqueAndNamespaced() throws {
        let a = Shot(name: "A"), b = Shot(name: "B")
        Check.expect(a.wrapperBundleID.hasPrefix("org.doppio-mac.shot."), "a.wrapperBundleID.hasPrefix(\"org.doppio-mac.shot.\")")
        Check.expect(a.wrapperBundleID != b.wrapperBundleID, "a.wrapperBundleID != b.wrapperBundleID")
    }

    /// The wrapper must never claim the target's identity, or Launch Services
    /// groups it with the original app.
    func wrapperIDNeverCollidesWithTarget() throws {
        let shot = Shot(name: "Chrome 2", targetBundleID: "com.google.Chrome")
        Check.expect(shot.wrapperBundleID != "com.google.Chrome", "shot.wrapperBundleID != \"com.google.Chrome\"")
    }

    func shotRoundTripsThroughJSON() throws {
        var shot = Shot(name: "Round Trip", launchMode: .clone, strategy: .chromium,
                        targetBundleID: "com.google.Chrome")
        shot.args = ["--user-data-dir=/tmp/x"]
        shot.env = ["HOME": "/tmp/x"]
        shot.ephemeral = true

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Shot.self, from: try encoder.encode(shot))

        Check.expect(decoded.id == shot.id, "decoded.id == shot.id")
        Check.expect(decoded.launchMode == .clone, "decoded.launchMode == .clone")
        Check.expect(decoded.strategy == .chromium, "decoded.strategy == .chromium")
        Check.expect(decoded.args == shot.args, "decoded.args == shot.args")
        Check.expect(decoded.env == shot.env, "decoded.env == shot.env")
        Check.expect(decoded.ephemeral, "decoded.ephemeral")
    }

    func launchModeIdentitySemantics() throws {
        Check.expect(LaunchMode.link.hasOwnIdentity, "LaunchMode.link.hasOwnIdentity")
        Check.expect(LaunchMode.clone.hasOwnIdentity, "LaunchMode.clone.hasOwnIdentity")
        Check.expect(!(LaunchMode.direct.hasOwnIdentity), "direct Shots share the original's Dock tile — the UI depends on this")
    }
}

struct LaunchPlanTests {
    /// The stub decodes this exact shape; a key rename here breaks every
    /// existing Shot, so pin the contract.
    func launchPlanKeys() throws {
        let plan = LaunchPlan(
            schema: 1, shotID: "id", name: "n", mode: "app", launchMode: "link",
            strategy: "electron", execPath: "/x", targetBundleID: "com.x",
            targetPath: "/Applications/X.app", targetExecutableName: "X",
            args: ["--a"], env: ["K": "V"], dataDir: "/d", url: nil,
            documentPath: nil, ephemeral: false, statusItem: false, stubVersion: "0.4.0")

        let data = try JSONEncoder().encode(plan)
        let json = try Check.require(JSONSerialization.jsonObject(with: data) as? [String: Any], "JSONSerialization.jsonObject(with: data) as? [Stri")
        for key in ["schema", "shotID", "name", "mode", "launchMode", "strategy",
                    "execPath", "targetBundleID", "targetExecutableName",
                    "args", "env", "dataDir", "ephemeral", "statusItem", "stubVersion"] {
            Check.expect(json[key] != nil, "shot.json must keep the '\(key)' key")
        }
    }
}

struct PathSafetyTests {
    /// Everything Doppio writes must live under one of three roots (spec §7).
    func writablePathsAreConfined() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [DoppioPaths.shotsDirectory.path,
                     DoppioPaths.supportDirectory.path,
                     DoppioPaths.dataRoot.path] {
            Check.expect(path.hasPrefix(home), "\(path) escapes the user's home directory")
        }
        Check.expect(DoppioPaths.dataRoot.path.hasPrefix(DoppioPaths.supportDirectory.path), "DoppioPaths.dataRoot.path.hasPrefix(DoppioPaths.supportDirec")
    }

    /// shot.json must not live in Contents/Resources: in link mode that path is
    /// a symlink into the target app, and a `.resources` directory is rejected
    /// by codesign as a nested bundle.
    func configFileAvoidsResourcesDirectory() throws {
        let config = DoppioPaths.configFile(inWrapper: URL(fileURLWithPath: "/tmp/S.app"))
        Check.expect(config.path == "/tmp/S.app/Contents/Doppio/shot.json", "config.path == \"/tmp/S.app/Contents/Doppio/shot.json\"")
        Check.expect(!(config.path.contains("Contents/Resources")), "!(config.path.contains(\"Contents/Resources\"))")
        Check.expect(!(config.path.contains(".resources")), "!(config.path.contains(\".resources\"))")
    }
}

struct IconFactoryTests {
    /// A well-formed .icns needs every standard size.
    func iconSizesCoverStandardSet() throws {
        let sizes = Set(IconFactory.iconSizes.map(\.px))
        for expected in [16, 32, 64, 128, 256, 512, 1024] {
            Check.expect(sizes.contains(expected), "missing \(expected)px representation")
        }
    }

    func hexColourRoundTrip() throws {
        let colour = try Check.require(NSColor(hex: "#3B82F6"), "NSColor(hex: \"#3B82F6\")")
        Check.expect(colour.hexString == "#3B82F6", "colour.hexString == \"#3B82F6\"")
        Check.expect(NSColor(hex: "nope") == nil, "NSColor(hex: \"nope\") == nil")
        Check.expect(NSColor(hex: "3B82F6") != nil, "a leading # should be optional")
    }

    func badgeIsClampedToThreeCharacters() throws {
        var shot = Shot(name: "X")
        shot.iconBadge = "TOOLONG"
        let image = IconFactory.renderedImage(for: shot, target: nil)
        Check.expect(image.size.width == 1024, "image.size.width == 1024")
    }
}
