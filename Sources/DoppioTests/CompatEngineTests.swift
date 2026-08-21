import Foundation
import DoppioCore

struct CompatEngineTests {
    /// The shipped database must load and cover the families the spec names.
    func bundledDatabaseLoads() throws {
        let engine = CompatEngine.loadBundledOnly()
        Check.expect(engine.rules.count >= 25, "the spec requires at least 25 verified entries")
        Check.expect(engine.rules.first { $0.id == "fallback" } != nil, "a fallback rule is required or unknown apps have no strategy")
    }

    func ruleIDsAreUnique() throws {
        let ids = CompatEngine.loadBundledOnly().rules.map(\.id)
        Check.expect(ids.count == Set(ids).count, "ids.count == Set(ids).count")
    }

    /// An exact bundle ID must beat framework sniffing: Chrome is a Chromium
    /// app, but it needs clone mode specifically.
    func exactBundleIDBeatsFrameworkSniffing() throws {
        let engine = CompatEngine.loadBundledOnly()
        let (rule, _) = engine.match(
            bundleID: "com.google.Chrome",
            frameworks: ["Electron Framework.framework"],
            sandboxed: false)
        Check.expect(rule.launchMode == .clone, "rule.launchMode == .clone")
        Check.expect(rule.strategy == .chromium, "rule.strategy == .chromium")
    }

    /// Longer prefixes win, so a specific rule can override a family rule.
    func longerPrefixWins() throws {
        let general = CompatRule(id: "general", bundleIDPrefixes: ["com.example"],
                                 strategy: .none, launchMode: .direct)
        let specific = CompatRule(id: "specific", bundleIDPrefixes: ["com.example.editor"],
                                  strategy: .electron, launchMode: .link)
        let engine = CompatEngine(rules: [general, specific])
        let (rule, _) = engine.match(bundleID: "com.example.editor", frameworks: [], sandboxed: false)
        Check.expect(rule.id == "specific", "rule.id == \"specific\"")
    }

    /// A prefix must match on a component boundary, not mid-identifier:
    /// `com.example.editorpro` is not `com.example.editor`.
    func prefixMatchesOnComponentBoundary() throws {
        let rule = CompatRule(id: "editor", bundleIDPrefixes: ["com.example.editor"],
                              strategy: .electron, launchMode: .link)
        Check.expect(rule.specificity(forBundleID: "com.example.editor") > 0, "rule.specificity(forBundleID: \"com.example.editor\") > 0")
        Check.expect(rule.specificity(forBundleID: "com.example.editor.beta") > 0, "rule.specificity(forBundleID: \"com.example.editor.beta\") >")
        Check.expect(rule.specificity(forBundleID: "com.example.editorpro") == 0, "rule.specificity(forBundleID: \"com.example.editorpro\") == ")
    }

    /// An unknown Electron app should work with no explicit entry.
    func frameworkSniffingCatchesUnknownElectronApps() throws {
        let engine = CompatEngine.loadBundledOnly()
        let (rule, reason) = engine.match(
            bundleID: "com.unknown.vendor.someapp",
            frameworks: ["Electron Framework.framework"],
            sandboxed: false)
        Check.expect(rule.strategy == .electron, "rule.strategy == .electron")
        Check.expect(reason.contains("Electron"), "the reason should explain the match: \(reason)")
    }

    /// Sandboxed apps must not be promised isolation they cannot get.
    ///
    /// The original theory was that a cloned bundle ID would receive its own
    /// container. Tested with WhatsApp on macOS 26.6: no container is created
    /// and the clone exits within seconds. So the honest answer for a sandboxed
    /// target is `direct` — a second instance sharing the original's data —
    /// rather than a clone that looks isolated and is not.
    func sandboxedAppsGetDirectMode() throws {
        let engine = CompatEngine.loadBundledOnly()
        let (rule, _) = engine.match(
            bundleID: "com.unknown.sandboxed",
            frameworks: ["Electron Framework.framework"],
            sandboxed: true)
        Check.expect(rule.launchMode == .direct,
                     "a sandboxed app cannot be isolated, so it must not be given a clone")
        Check.expect(rule.strategy == IsolationStrategy.none,
                     "a sandboxed app must not claim to isolate data")
    }

    func unknownAppFallsBack() throws {
        let engine = CompatEngine.loadBundledOnly()
        let (rule, _) = engine.match(bundleID: "com.nothing.matches", frameworks: [], sandboxed: false)
        Check.expect(rule.id == "fallback", "rule.id == \"fallback\"")
    }

    /// Every Chromium-family rule must use clone mode: the M0 spike showed a
    /// symlink wrapper breaks their sandboxed helper processes.
    func chromiumRulesUseCloneMode() throws {
        for rule in CompatEngine.loadBundledOnly().rules where rule.strategy == .chromium {
            Check.expect(rule.launchMode == .clone, "rule '\(rule.id)' would produce a Shot that cannot start")
        }
    }

    /// Any rule that isolates data must actually say how.
    func isolatingRulesCarryTheirMechanism() throws {
        for rule in CompatEngine.loadBundledOnly().rules {
            switch rule.strategy {
            case .chromium, .electron:
                Check.expect(rule.extraArgs.contains { $0.contains("--user-data-dir") }, "rule '\(rule.id)' claims \(rule.strategy) but passes no user-data-dir")
            case .firefox:
                Check.expect(rule.extraArgs.contains { $0.contains("no-remote") }, "rule '\(rule.id)' needs -no-remote or Firefox refuses a second instance")
            case .env:
                Check.expect(!(rule.extraEnv.isEmpty), "rule '\(rule.id)' uses the env strategy but sets no variables")
            case .home, .none:
                break
            }
        }
    }
}

struct LaunchModeSafetyTests {
    /// The whole Electron catalogue must use clone mode. Link mode produces a
    /// Shot that dies with "Unable to find helper app", so shipping a link rule
    /// for an Electron family would mean shipping a broken Shot.
    func electronRulesUseCloneMode() throws {
        for rule in CompatEngine.loadBundledOnly().rules where rule.strategy == .electron {
            Check.equal(rule.launchMode, .clone,
                        "rule '\(rule.id)' would produce a Shot that cannot start")
        }
    }

    /// No shipped rule may default to link mode until someone has verified that
    /// specific app family actually starts under it.
    func noShippedRuleDefaultsToLink() throws {
        for rule in CompatEngine.loadBundledOnly().rules {
            Check.expect(rule.launchMode != .link,
                         "rule '\(rule.id)' defaults to link, which is unverified for helper-based apps")
        }
    }

    /// The guard must upgrade a hand-written link Shot for an Electron target.
    func guardUpgradesElectronLinkShots() throws {
        let shot = Shot(name: "X", launchMode: .link, strategy: .electron,
                        targetBundleID: "com.anthropic.claudefordesktop")
        Check.equal(BundleForge.viableLaunchMode(for: shot, target: nil), .clone,
                    "an Electron link Shot must be upgraded to clone")
    }

    /// Chromium likewise.
    func guardUpgradesChromiumLinkShots() throws {
        let shot = Shot(name: "X", launchMode: .link, strategy: .chromium,
                        targetBundleID: "com.google.Chrome")
        Check.equal(BundleForge.viableLaunchMode(for: shot, target: nil), .clone, "a Chromium link Shot must be upgraded to clone")
    }

    /// A plain app with no isolation flags is left alone.
    func guardLeavesSimpleAppsAlone() throws {
        let shot = Shot(name: "X", launchMode: .link, strategy: .home)
        Check.equal(BundleForge.viableLaunchMode(for: shot, target: nil), .link, "a simple app should keep link mode")
    }

    /// direct mode is never rewritten.
    func guardNeverRewritesDirect() throws {
        let shot = Shot(name: "X", launchMode: .direct, strategy: .electron)
        Check.equal(BundleForge.viableLaunchMode(for: shot, target: nil), .direct, "direct mode is never rewritten")
    }
}
