import Foundation
import AppKit

/// Removes everything Doppio has put on the machine.
///
/// The spec promised a "Remove everything" action and it never existed, which
/// matters more for this app than most: Doppio scatters generated bundles
/// across `~/Applications/Doppio`, per-Shot data under Application Support, and
/// WebKit stores keyed by each Shot's bundle identifier. Someone removing
/// Doppio by dragging it to the Trash would leave all of that behind.
///
/// Every path is proven to be inside a directory Doppio owns before it is
/// touched, and the plan can be inspected before anything is removed.
public struct Uninstaller {
    /// One thing that would be removed.
    public struct Item: Sendable {
        public enum Kind: String, Sendable {
            case shotBundle, shotData, webKitStore, supportDirectory, commandLineTool, application
        }
        public var kind: Kind
        public var path: String
        public var bytes: Int64
        public var describedAs: String
    }

    public struct Plan: Sendable {
        public var items: [Item]
        /// Paths that were skipped because they are outside Doppio's own
        /// directories — a Shot whose data the user pointed at Dropbox, say.
        public var skipped: [String]

        public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
        public var isEmpty: Bool { items.isEmpty }
    }

    public let shots: [Shot]
    public let keepData: Bool
    public let removeApplication: Bool

    public init(shots: [Shot], keepData: Bool = false, removeApplication: Bool = true) {
        self.shots = shots
        self.keepData = keepData
        self.removeApplication = removeApplication
    }

    // MARK: - Planning

    /// Works out what would be removed, without removing anything.
    public func plan() -> Plan {
        let fm = FileManager.default
        var items: [Item] = []
        var skipped: [String] = []

        for shot in shots {
            // The Shot's bundle.
            let bundle = shot.bundleURL
            if fm.fileExists(atPath: bundle.path) {
                if PathGuard.isStrictlyInside(bundle, within: DoppioPaths.shotsDirectory) {
                    items.append(Item(kind: .shotBundle, path: bundle.path,
                                      bytes: Self.size(of: bundle),
                                      describedAs: "Shot “\(shot.name)”"))
                } else {
                    skipped.append(bundle.path)
                }
            }

            // Its data, unless the user is keeping it.
            if !keepData {
                if fm.fileExists(atPath: shot.dataDir) {
                    if PathGuard.isStrictlyInside(shot.dataDirURL, within: DoppioPaths.dataRoot) {
                        items.append(Item(kind: .shotData, path: shot.dataDir,
                                          bytes: Self.size(of: shot.dataDirURL),
                                          describedAs: "data for “\(shot.name)”"))
                    } else {
                        // A Shot pointed at Dropbox or an external disk is the
                        // user's own folder and is never removed.
                        skipped.append(shot.dataDir)
                    }
                }

                // A web Shot's real storage is WebKit's, keyed by bundle ID.
                for store in Self.webKitStores(for: shot) where fm.fileExists(atPath: store.path) {
                    items.append(Item(kind: .webKitStore, path: store.path,
                                      bytes: Self.size(of: store),
                                      describedAs: "website data for “\(shot.name)”"))
                }
            }
        }

        // Doppio's own support directory: the library index, user rules, and
        // any per-Shot data belonging to Shots no longer in the library.
        if !keepData, fm.fileExists(atPath: DoppioPaths.supportDirectory.path) {
            // Sized without the per-Shot data directories, which are itemised
            // above — counting the whole tree here would double the total.
            let alreadyCounted = items
                .filter { $0.kind == .shotData }
                .reduce(Int64(0)) { $0 + $1.bytes }
            let remainder = max(0, Self.size(of: DoppioPaths.supportDirectory) - alreadyCounted)
            items.append(Item(kind: .supportDirectory, path: DoppioPaths.supportDirectory.path,
                              bytes: remainder,
                              describedAs: "Doppio's settings, and data for any Shots no longer listed"))
        }

        // The command line tool, but only if it points back into Doppio.
        if let cli = Self.doppioOwnedCommandLineTool() {
            items.append(Item(kind: .commandLineTool, path: cli.path, bytes: 0,
                              describedAs: "the doppio command"))
        }

        if removeApplication, let app = Self.installedApplication() {
            items.append(Item(kind: .application, path: app.path,
                              bytes: Self.size(of: app),
                              describedAs: "Doppio itself"))
        }

        return Plan(items: items, skipped: skipped)
    }

    // MARK: - Executing

    /// Removes everything in the plan. Returns whatever could not be removed.
    @discardableResult
    public func removeEverything(_ plan: Plan) -> [String] {
        let fm = FileManager.default
        var failures: [String] = []

        // The application goes last: the running CLI may live inside it.
        let ordered = plan.items.sorted { a, b in
            (a.kind == .application ? 1 : 0) < (b.kind == .application ? 1 : 0)
        }

        for item in ordered {
            let url = URL(fileURLWithPath: item.path)
            guard Self.isSafeToRemove(url, kind: item.kind) else {
                failures.append("\(item.path) (refused: outside Doppio's own directories)")
                continue
            }
            do {
                try fm.removeItem(at: url)
            } catch {
                failures.append("\(item.path) (\(error.localizedDescription))")
            }
        }
        return failures
    }

    /// Final containment check, immediately before each delete.
    ///
    /// The plan was built earlier and could in principle be stale, and these are
    /// recursive deletes, so each path is re-proven rather than trusted.
    public static func isSafeToRemove(_ url: URL, kind: Item.Kind) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch kind {
        case .shotBundle:
            return PathGuard.isStrictlyInside(url, within: DoppioPaths.shotsDirectory)
        case .shotData:
            return PathGuard.isStrictlyInside(url, within: DoppioPaths.dataRoot)
        case .webKitStore:
            return PathGuard.isStrictlyInside(url, within: home.appendingPathComponent("Library/WebKit"))
        case .supportDirectory:
            return PathGuard.canonical(url) == PathGuard.canonical(DoppioPaths.supportDirectory)
        case .commandLineTool:
            // Only ever a symlink that points into Doppio.
            return doppioOwnedCommandLineTool().map { PathGuard.canonical($0) == PathGuard.canonical(url) } ?? false
        case .application:
            return installedApplication().map { PathGuard.canonical($0) == PathGuard.canonical(url) } ?? false
        }
    }

    // MARK: - Locating

    static func webKitStores(for shot: Shot) -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit")
        return [
            root.appendingPathComponent(shot.wrapperBundleID),
            root.appendingPathComponent("WebsiteDataStore/\(shot.id.uuidString.lowercased())"),
        ]
    }

    /// The `doppio` symlink, but only when it actually points into a Doppio
    /// bundle — never a same-named binary someone else installed.
    public static func doppioOwnedCommandLineTool() -> URL? {
        let candidate = URL(fileURLWithPath: "/usr/local/bin/doppio")
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: candidate.path),
              (attributes[.type] as? FileAttributeType) == .typeSymbolicLink,
              let destination = try? fm.destinationOfSymbolicLink(atPath: candidate.path)
        else { return nil }
        return destination.contains("Doppio.app/Contents/Resources/doppio") ? candidate : nil
    }

    /// Where Doppio itself is installed, if it can be found.
    public static func installedApplication() -> URL? {
        let fm = FileManager.default
        let candidates = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Doppio.app"),
            URL(fileURLWithPath: "/Applications/Doppio.app"),
        ]
        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            let plist = BundleInspector.plist(at: candidate.appendingPathComponent("Contents/Info.plist"))
            if plist?["CFBundleIdentifier"] as? String == "org.doppio-mac.Doppio" { return candidate }
        }
        return nil
    }

    static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }

    public static func humanBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
