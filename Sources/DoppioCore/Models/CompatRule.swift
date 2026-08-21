import Foundation

/// One entry in the community compatibility database.
///
/// Rules are matched against a target app to decide how to isolate it and how
/// to give it its own identity.
///
/// Shipped under the project licence (PolyForm Noncommercial 1.0.0), which
/// permits noncommercial redistribution — so rules contributed here stay
/// shareable.
///
/// `verifiedOn` is non-nil only for rules that were actually launched
/// end-to-end. A nil value means the rule is a considered starting point, not a
/// tested fact — see `docs/compat-testing.md`.
public struct CompatRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// Bundle-ID prefixes this rule applies to, e.g. `com.google.Chrome`.
    public var bundleIDPrefixes: [String]
    /// Frameworks whose presence inside the target bundle implies this rule,
    /// e.g. `Electron Framework.framework`. Lets unknown Electron/Chromium
    /// apps work with no explicit entry.
    public var frameworks: [String]
    public var strategy: IsolationStrategy
    public var launchMode: LaunchMode
    /// Extra arguments. `${dataDir}` is substituted at generation time.
    public var extraArgs: [String]
    public var extraEnv: [String: String]
    public var notes: String?
    public var verifiedOn: String?
    public var contributor: String?

    public init(
        id: String,
        bundleIDPrefixes: [String] = [],
        frameworks: [String] = [],
        strategy: IsolationStrategy,
        launchMode: LaunchMode,
        extraArgs: [String] = [],
        extraEnv: [String: String] = [:],
        notes: String? = nil,
        verifiedOn: String? = nil,
        contributor: String? = nil
    ) {
        self.id = id
        self.bundleIDPrefixes = bundleIDPrefixes
        self.frameworks = frameworks
        self.strategy = strategy
        self.launchMode = launchMode
        self.extraArgs = extraArgs
        self.extraEnv = extraEnv
        self.notes = notes
        self.verifiedOn = verifiedOn
        self.contributor = contributor
    }

    /// How specific this rule is. Bundle-ID matches beat framework sniffing,
    /// and a longer prefix beats a shorter one.
    public func specificity(forBundleID bundleID: String) -> Int {
        var score = 0
        for prefix in bundleIDPrefixes where bundleID == prefix || bundleID.hasPrefix(prefix + ".") {
            score = max(score, 1000 + prefix.count)
        }
        return score
    }
}

/// The on-disk format of `rules.json`.
public struct CompatDatabase: Codable, Sendable {
    public var schema: Int
    public var updated: String
    public var rules: [CompatRule]

    public init(schema: Int = 1, updated: String, rules: [CompatRule]) {
        self.schema = schema
        self.updated = updated
        self.rules = rules
    }
}
