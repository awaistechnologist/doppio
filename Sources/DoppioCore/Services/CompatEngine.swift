import Foundation

/// Matches installed apps against the compatibility database.
///
/// Matching order, most specific first:
///  1. exact bundle ID / longest bundle-ID prefix
///  2. framework sniffing inside the target bundle (makes unknown
///     Electron/Chromium apps work with no explicit rule)
///  3. the `fallback` rule
public struct CompatEngine: Sendable {
    public let rules: [CompatRule]

    public init(rules: [CompatRule]) {
        self.rules = rules
    }

    /// Loads the bundled database, then layers any user-supplied rules on top
    /// (user rules with the same `id` win, so a local fix beats a stale ship).
    public static func loadDefault() -> CompatEngine {
        var merged: [String: CompatRule] = [:]
        for rule in loadBundled() { merged[rule.id] = rule }
        for rule in loadUserRules() { merged[rule.id] = rule }
        // Sorted, so two rules of equal specificity always tie-break the same
        // way — dictionary order made matching nondeterministic between runs.
        return CompatEngine(rules: merged.values.sorted { $0.id < $1.id })
    }

    /// The shipped database only, with no user rules layered on.
    ///
    /// Tests use this: `loadDefault()` merges `~/Library/Application
    /// Support/Doppio/rules.json`, so a rule a developer happens to have
    /// installed would change test results on their machine and nowhere else.
    public static func loadBundledOnly() -> CompatEngine {
        CompatEngine(rules: loadBundled().sorted { $0.id < $1.id })
    }

    static func loadBundled() -> [CompatRule] {
        // Resource bundle when built by SwiftPM, else a sibling file: the CLI
        // and the app both need this to work outside a .app wrapper.
        var candidates: [URL] = []
        if let u = Bundle.module.url(forResource: "rules", withExtension: "json") {
            candidates.append(u)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/rules.json"))
        for url in candidates {
            if let db = try? decode(url) { return db.rules }
        }
        return []
    }

    static func loadUserRules() -> [CompatRule] {
        (try? decode(DoppioPaths.userRulesFile))?.rules ?? []
    }

    static func decode(_ url: URL) throws -> CompatDatabase {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CompatDatabase.self, from: data)
    }

    /// The best rule for a target, plus how it was chosen.
    public func match(bundleID: String, frameworks: Set<String>, sandboxed: Bool) -> (rule: CompatRule, reason: String) {
        // 1. bundle-ID match
        var best: CompatRule?
        var bestScore = 0
        for rule in rules.sorted(by: { $0.id < $1.id }) {
            let score = rule.specificity(forBundleID: bundleID)
            if score > bestScore { bestScore = score; best = rule }
        }
        if let best {
            return (best, "matched bundle ID against rule '\(best.id)'")
        }

        // 2. sandbox detection outranks generic framework sniffing: a sandboxed
        //    Electron app cannot be isolated with --user-data-dir alone.
        if sandboxed, let rule = rules.first(where: { $0.frameworks.contains("__SANDBOXED__") }) {
            return (rule, "target is sandboxed — using rule '\(rule.id)'")
        }

        // 3. framework sniffing
        for rule in rules.sorted(by: { $0.id < $1.id }) {
            for framework in rule.frameworks where framework != "__SANDBOXED__" {
                if frameworks.contains(framework) {
                    return (rule, "detected \(framework) — using rule '\(rule.id)'")
                }
            }
        }

        // 4. fallback
        if let fallback = rules.first(where: { $0.id == "fallback" }) {
            return (fallback, "no rule matched — using the generic fallback")
        }
        return (CompatRule(id: "builtin-fallback", strategy: .home, launchMode: .link),
                "no database available — using built-in defaults")
    }

    public func match(for app: TargetApp) -> (rule: CompatRule, reason: String) {
        let inspection = BundleInspector.inspect(app.url)
        return match(bundleID: app.bundleID, frameworks: inspection.frameworks, sandboxed: inspection.sandboxed)
    }
}
