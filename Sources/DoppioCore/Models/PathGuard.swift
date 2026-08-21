import Foundation

/// Containment checks for every destructive or write operation.
///
/// Doppio deletes directories recursively (a Shot's bundle, a Shot's data
/// directory, an ephemeral Shot's data on quit). Each of those paths is derived
/// from user-supplied text — a Shot's name, a `--data-dir` argument, a
/// hand-edited `library.json` — so each needs proving to be inside the root it
/// is supposed to be inside.
///
/// A raw `hasPrefix` is not sufficient and was the original bug here:
///
/// - `.../Shots/../../../../Documents` passes a prefix test and resolves to
///   `~/Documents`;
/// - `.../Shots Backups` passes a prefix test because there is no separator
///   boundary.
public enum PathGuard {
    /// Canonical form used for every comparison: `..` collapsed and symlinks
    /// resolved as far as the path exists.
    ///
    /// Comparison is case-sensitive. On a case-insensitive volume (the macOS
    /// default) that can only ever *refuse* a path that would in fact have been
    /// contained — never admit one that escapes — so it fails safe.
    public static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// True when `path` is `root` itself or lies inside it.
    public static func isContained(_ path: URL, within root: URL) -> Bool {
        let target = canonical(path)
        let base = canonical(root)
        // The separator is what stops "/a/b Backups" matching root "/a/b".
        return target == base || target.hasPrefix(base + "/")
    }

    /// Like `isContained`, but requires the path to be strictly *inside* the
    /// root. Deleting the root itself is never what Doppio wants.
    public static func isStrictlyInside(_ path: URL, within root: URL) -> Bool {
        let target = canonical(path)
        let base = canonical(root)
        return target != base && target.hasPrefix(base + "/")
    }

    public static func assertStrictlyInside(_ path: URL, within root: URL,
                                            what: String) throws {
        guard isStrictlyInside(path, within: root) else {
            throw PathGuardError.escapes(what: what,
                                         resolved: canonical(path),
                                         root: canonical(root))
        }
    }
}

public enum PathGuardError: LocalizedError {
    case escapes(what: String, resolved: String, root: String)
    case unsafeName(String)

    public var errorDescription: String? {
        switch self {
        case .escapes(let what, let resolved, let root):
            return "Refused to touch \(what): it resolves to \(resolved), which is outside \(root)."
        case .unsafeName(let name):
            return """
            “\(name)” cannot be used as a Shot name. Names become filenames, so \
            they cannot contain “/” or “..”, or start with a dot.
            """
        }
    }
}

extension Shot {
    /// Characters that would let a name escape the Shots directory or produce a
    /// hidden or unusable bundle.
    public static func isSafeName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix(".") { return false }
        if trimmed.contains("/") || trimmed.contains("\\") { return false }
        if trimmed.contains("..") { return false }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        if trimmed.utf8.count > 200 { return false }
        return true
    }

    /// A filename that cannot escape the Shots directory, whatever `name`
    /// contains. `bundleURL` is built from this rather than from `name`
    /// directly, so even a hand-edited `library.json` cannot aim a delete at
    /// another application.
    public var fileSafeName: String {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", "\\", ":"] { cleaned = cleaned.replacingOccurrences(of: bad, with: "-") }
        // Loop to a fixed point: a single pass turns "a....b" into "a..b".
        // Traversal is already impossible once "/" is gone, but the name should
        // match what the tests claim it is.
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: ".")
        }
        cleaned = String(String.UnicodeScalarView(
            cleaned.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.utf8.count > 200 { cleaned = String(cleaned.prefix(60)) }
        // Never return empty: fall back to the Shot's own identifier.
        return cleaned.isEmpty ? "Shot-\(id.uuidString.prefix(8))" : cleaned
    }
}


extension Shot {
    /// Web Shots accept only http(s).
    ///
    /// Anything else is either meaningless in a WKWebView shell or actively
    /// unsafe (`javascript:`, `file:`), and a bare `URL(string:)` check accepts
    /// both. Plain `http` is allowed but needs the wrapper's App Transport
    /// Security exception, or the page is accepted at creation time and then
    /// silently refuses to load.
    public static func normalisedWebURL(_ text: String) -> URL? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// True when the Shot's URL needs the plain-HTTP exception.
    public var needsInsecureHTTP: Bool {
        guard mode == .web, let url = url.flatMap(URL.init(string:)) else { return false }
        return url.scheme?.lowercased() == "http"
    }
}
