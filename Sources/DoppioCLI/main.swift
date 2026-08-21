import Foundation
import AppKit
import DoppioCore

// doppio — the command line interface the commercial alternatives don't have.
// Everything the GUI can do, scriptable, with --json for machine consumption.

let version = DoppioPaths.appVersion

struct Options {
    /// Options that never take a value.
    static let booleanFlags: Set<String> = [
        "all", "quick", "keep-running", "verify", "launch-now",
        "ephemeral", "status-item", "data", "yes", "json", "force",
        "dry-run", "keep-data", "keep-app",
    ]

    var json = false
    var yes = false
    var values: [String: String] = [:]
    var positional: [String] = []

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--json" { options.json = true; index += 1; continue }
            if argument == "--yes" || argument == "-y" { options.yes = true; index += 1; continue }
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    options.values[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
                } else if Self.booleanFlags.contains(name) {
                    // Flags that take no value must not consume the next word,
                    // or `doppio verify --quick "Name"` eats the Shot name.
                    options.values[name] = "true"
                } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    options.values[name] = arguments[index + 1]
                    index += 1
                } else {
                    options.values[name] = "true"
                }
                index += 1
                continue
            }
            options.positional.append(argument)
            index += 1
        }
        return options
    }
}

func fail(_ message: String, json: Bool) -> Never {
    if json {
        print(#"{"ok":false,"error":\#(quote(message))}"#)
    } else {
        FileHandle.standardError.write("doppio: \(message)\n".data(using: .utf8)!)
    }
    exit(EXIT_FAILURE)
}

func quote(_ string: String) -> String {
    let data = try! JSONEncoder().encode(string)
    return String(data: data, encoding: .utf8)!
}

func usage() {
    print("""
    doppio \(version) — run multiple independent instances of any Mac app.

    USAGE
      doppio create --app <name|bundle-id> [options]
      doppio create --url <url> --name <name> [options]
      doppio create --file <path> [--with <app>] [--name <name>]
      doppio list [--json]
      doppio launch <name>
      doppio remove <name> [--data] [--yes] [--force]
      doppio verify <name|--all> [--quick] [--keep-running]
      doppio regenerate <name|--all> [--force]
      doppio info <name> [--json]
      doppio apps [--json]
      doppio rules [--json]
      doppio doctor [--json]
      doppio uninstall [--dry-run] [--keep-data] [--keep-app] [--yes] [--json]

    --force is needed to regenerate or remove a Shot while it is running:
    rebuilding swaps the bundle underneath the live process.

    UNINSTALL
      Removes everything Doppio put on this machine: every Shot, its data, its
      website data, Doppio's settings, the doppio command, and Doppio itself.
      Always prints exactly what it will remove first. --dry-run stops there.
      --keep-data leaves Shot data and settings alone; --keep-app leaves
      Doppio.app in place. Data you pointed somewhere of your own (Dropbox, an
      external disk) is never removed, and is listed as skipped.

    VERIFY
      Runs the compatibility checklist against a Shot: signature, provenance,
      the original app's signature, then launches it and checks that it really
      runs, that helper processes are alive, that data lands in its own folder,
      and that nothing crashed. --quick skips the launch.

    CREATE OPTIONS
      --name <text>        Shot name (default: "<App> 2")
      --isolate <mode>     auto | chromium | electron | firefox | home | env | none
      --launch <mode>      auto | link | clone | direct
      --data-dir <path>    Where the Shot keeps its data
      --badge <text>       Up to 3 characters drawn on the icon
      --tint <#RRGGBB>     Icon tint
      --ephemeral          Erase the Shot's data when it quits
      --status-item        Show a menu bar item while the Shot runs
      --arg <value>        Extra argument (repeatable via --arg a --arg b)
      --env K=V            Extra environment variable (repeatable)
      --appearance <mode>  system | light
                           (dark is not expressible: the macOS plist key can
                           only force light appearance)
      --launch-now         Launch the Shot after creating it
      --verify             Run the full checklist (launches the Shot) after creating

    Launch modes decide how a Shot gets its own Dock icon:
      clone   copy-on-write clone — own icon, works for every app family
              tested, needs regenerating after the app updates (default)
      link    symlink wrapper — own icon and survives app updates, but only
              for simple apps: it does NOT work for Chromium or Electron
      direct  second instance sharing the original's Dock icon (always works)
    """)
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage(); exit(EXIT_SUCCESS) }
let options = Options.parse(Array(arguments.dropFirst()))

@MainActor
func runCLI() {
switch command {
case "help", "--help", "-h":
    usage()

case "version", "--version", "-v":
    print(version)

case "apps":
    let apps = AppScanner().scan()
    if options.json {
        let engine = CompatEngine.loadDefault()
        let entries = apps.map { app -> [String: Any] in
            let (rule, _) = engine.match(for: app)
            return ["name": app.name, "bundleID": app.bundleID, "path": app.path,
                    "version": app.version ?? "", "rule": rule.id,
                    "strategy": rule.strategy.rawValue, "launchMode": rule.launchMode.rawValue]
        }
        let data = try! JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } else {
        for app in apps { print("\(app.name.padded(34)) \(app.bundleID)") }
        print("\n\(apps.count) applications")
    }

case "rules":
    let engine = CompatEngine.loadDefault()
    if options.json {
        let data = try! JSONEncoder().encode(engine.rules.sorted { $0.id < $1.id })
        print(String(data: data, encoding: .utf8)!)
    } else {
        for rule in engine.rules.sorted(by: { $0.id < $1.id }) {
            print("\(rule.id.padded(22)) \(rule.strategy.rawValue.padded(10)) \(rule.launchMode.rawValue.padded(8)) \(rule.bundleIDPrefixes.count) ids")
        }
        print("\n\(engine.rules.count) rules")
    }

case "list":
    let library = ShotLibrary()
    let shots = library.shots
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try! encoder.encode(shots), encoding: .utf8)!)
    } else if shots.isEmpty {
        print("No Shots yet. Create one with:\n  doppio create --app \"Google Chrome\"")
    } else {
        for shot in shots {
            let health = library.health(of: shot)
            let running = library.isRunning(shot)
            var flags: [String] = [shot.launchMode.rawValue, shot.strategy.rawValue]
            if running { flags.append("running") }
            if health.isProblem { flags.append("needs attention") }
            print("\(shot.name.padded(30)) \(flags.joined(separator: ", "))")
        }
        print("\n\(shots.count) Shots in \(DoppioPaths.shotsDirectory.path)")
    }

case "info":
    guard let name = options.positional.first else { fail("info needs a Shot name", json: options.json) }
    let library = ShotLibrary()
    guard let shot = library.shots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
        fail("no Shot named \(name)", json: options.json)
    }
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try! encoder.encode(shot), encoding: .utf8)!)
    } else {
        print("""
        \(shot.name)
          bundle        \(shot.bundleURL.path)
          bundle ID     \(shot.wrapperBundleID)
          mode          \(shot.mode.rawValue)
          launch mode   \(shot.launchMode.rawValue) — \(shot.launchMode.explanation)
          isolation     \(shot.strategy.rawValue) (\(shot.strategy.title))
          target        \(shot.targetBundleID ?? shot.url ?? "—")
          data          \(shot.dataDir)
          args          \(shot.args.isEmpty ? "—" : shot.args.joined(separator: " "))
          env           \(shot.env.isEmpty ? "—" : shot.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
          ephemeral     \(shot.ephemeral)
          health        \(library.health(of: shot))
        """)
    }

case "create":
    let library = ShotLibrary()
    var shot: Shot

    if let urlString = options.values["url"] {
        guard let name = options.values["name"] else {
            fail("a web Shot needs --name", json: options.json)
        }
        guard let url = Shot.normalisedWebURL(urlString) else {
            fail("not a usable web address: \(urlString) (http and https only)", json: options.json)
        }
        shot = Shot(name: name, mode: .web, launchMode: .link, strategy: .none, url: url.absoluteString)
    } else if let appName = options.values["app"] {
        guard let app = AppScanner().find(appName) else {
            fail("no installed app matching “\(appName)”. Try: doppio apps", json: options.json)
        }
        let suggestion = library.suggestedShot(for: app)
        shot = suggestion.shot
        if !options.json {
            print("Target:    \(app.name) (\(app.bundleID))")
            print("Rule:      \(suggestion.reason)")
        }
    } else if let filePath = options.values["file"] {
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("no such file: \(url.path)", json: options.json)
        }
        let name = options.values["name"] ?? url.deletingPathExtension().lastPathComponent
        var bundleID: String?
        if let opener = options.values["with"], let app = AppScanner().find(opener) {
            bundleID = app.bundleID
        }
        shot = Shot(name: name, mode: .file, launchMode: .link, strategy: .none,
                    targetBundleID: bundleID, documentPath: url.path)
    } else {
        fail("create needs --app, --url or --file", json: options.json)
    }

    if let name = options.values["name"] { shot.name = name }
    if let isolate = options.values["isolate"], isolate != "auto" {
        guard let strategy = IsolationStrategy(rawValue: isolate) else {
            fail("unknown isolation mode: \(isolate)", json: options.json)
        }
        shot.strategy = strategy
    }
    if let launch = options.values["launch"], launch != "auto" {
        guard let mode = LaunchMode(rawValue: launch) else {
            fail("unknown launch mode: \(launch)", json: options.json)
        }
        shot.launchMode = mode
    }
    if let dataDir = options.values["data-dir"] {
        let expanded = (dataDir as NSString).expandingTildeInPath
        // Keep ${dataDir}-derived arguments pointing at the new location.
        shot.args = shot.args.map { $0.replacingOccurrences(of: shot.dataDir, with: expanded) }
        shot.env = shot.env.mapValues { $0.replacingOccurrences(of: shot.dataDir, with: expanded) }
        shot.dataDir = expanded
    }
    if let badge = options.values["badge"] { shot.iconBadge = badge }
    if let tint = options.values["tint"] { shot.iconTint = tint }
    if options.values["ephemeral"] != nil { shot.ephemeral = true }
    if options.values["status-item"] != nil { shot.statusItem = true }
    if let appearance = options.values["appearance"] {
        guard let value = Shot.Appearance(rawValue: appearance) else {
            fail("unknown appearance: \(appearance) (system or light)", json: options.json)
        }
        guard value != .dark else {
            fail("dark appearance cannot be forced: NSRequiresAquaSystemAppearance only forces light",
                 json: options.json)
        }
        shot.appearance = value
    }
    // --arg / --env may appear more than once; Options keeps the last, so
    // re-scan the raw arguments to collect them all.
    let rawArguments = Array(arguments.dropFirst())
    for (index, argument) in rawArguments.enumerated() where argument == "--arg" && index + 1 < rawArguments.count {
        shot.args.append(rawArguments[index + 1])
    }
    for (index, argument) in rawArguments.enumerated() where argument == "--env" && index + 1 < rawArguments.count {
        let pair = rawArguments[index + 1]
        if let equals = pair.firstIndex(of: "=") {
            shot.env[String(pair[pair.startIndex..<equals])] = String(pair[pair.index(after: equals)...])
        }
    }

    let saved = library.save(shot)
    guard saved else {
        fail(library.lastError ?? "could not create the Shot", json: options.json)
    }

    // Never report success on a structurally broken Shot. The static checks
    // are cheap and launch nothing, so they run every time.
    //
    // In JSON mode exactly one document must reach stdout, and its "ok" must
    // agree with the exit code — printing a success object and then a failure
    // object produced output no script could parse.
    let verifier = ShotVerifier(library: library)
    var problems: [String] = []
    for check in ShotVerifier.staticChecks(for: shot) where check.outcome == .failed {
        problems.append("\(check.name): \(check.detail)")
    }

    var runtimeChecks: [VerificationCheck] = []
    if problems.isEmpty, options.values["verify"] != nil {
        let report = verifier.verify(shot, runtime: true)
        runtimeChecks = report.checks
        for check in report.failures { problems.append("\(check.name): \(check.detail)") }
    }

    if options.json {
        var payload: [String: Any] = [
            "ok": problems.isEmpty,
            "created": true,
            "name": shot.name,
            "bundle": shot.bundleURL.path,
            "bundleID": shot.wrapperBundleID,
            "launchMode": shot.launchMode.rawValue,
            "strategy": shot.strategy.rawValue,
            "dataDir": shot.dataDir,
        ]
        if !problems.isEmpty { payload["problems"] = problems }
        if !runtimeChecks.isEmpty {
            payload["checks"] = runtimeChecks.map {
                ["name": $0.name, "outcome": $0.outcome.rawValue, "detail": $0.detail]
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } else {
        print("Launch:    \(shot.launchMode.rawValue) — \(shot.launchMode.explanation)")
        if shot.launchMode == .clone, shot.mode == .app,
           let target = AppScanner.resolve(bundleID: shot.targetBundleID, fallbackPath: shot.targetPath),
           !BundleForge.cloneIsCopyOnWrite(target: target) {
            print("Note:      \(target.name) is on a different volume, so this clone is a real")
            print("           byte copy rather than a free copy-on-write clone.")
        }
        print("Isolation: \(shot.strategy.title)")
        print("Data:      \(shot.dataDir)")
        print("\nCreated \(shot.bundleURL.path)")
        for check in runtimeChecks {
            let detail = check.detail.isEmpty ? "" : "  — \(check.detail)"
            print("  \(check.symbol) \(check.name)\(detail)")
        }
        if !problems.isEmpty {
            print("\nWARNING: this Shot was created but failed verification:")
            for problem in problems { print("  ✗ \(problem)") }
            print("\nRun: doppio verify \"\(shot.name)\"")
        }
    }
    if !problems.isEmpty { exit(EXIT_FAILURE) }

    if options.values["launch-now"] != nil, let error = library.launchSynchronously(shot) {
        // launch()'s error callback never runs on the CLI's runloop-less main
        // thread, so failures were reported as success.
        fail(error, json: options.json)
    }

case "launch":
    guard let name = options.positional.first else { fail("launch needs a Shot name", json: options.json) }
    let library = ShotLibrary()
    guard let shot = library.shots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
        fail("no Shot named \(name)", json: options.json)
    }
    if let error = library.launchSynchronously(shot) {
        fail(error, json: options.json)
    }
    if options.json { print(#"{"ok":true,"launched":\#(quote(shot.name))}"#) } else { print("Launched \(shot.name)") }

case "remove":
    guard let name = options.positional.first else { fail("remove needs a Shot name", json: options.json) }
    let library = ShotLibrary()
    guard let shot = library.shots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
        fail("no Shot named \(name)", json: options.json)
    }
    let alsoData = options.values["data"] != nil
    // --json does not imply consent. A script deleting data must pass --yes.
    if !options.yes && options.json {
        fail("remove needs --yes when used with --json", json: true)
    }
    if !options.yes {
        print("Remove “\(shot.name)”\(alsoData ? " and its data directory" : "")? [y/N] ", terminator: "")
        guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
            print("Cancelled."); exit(EXIT_SUCCESS)
        }
    }
    library.delete(shot, includingData: alsoData, force: options.values["force"] != nil)
    // delete() reports refusal through lastError; printing "Removed" without
    // checking it claimed success for a Shot that is still there.
    if let error = library.lastError {
        fail(error, json: options.json)
    }
    if options.json { print(#"{"ok":true,"removed":\#(quote(shot.name))}"#) } else { print("Removed \(shot.name)") }

case "verify":
    let library = ShotLibrary()
    let all = options.values["all"] != nil
    let targets: [Shot]
    if all {
        targets = library.shots
    } else {
        guard let name = options.positional.first else {
            fail("verify needs a Shot name or --all", json: options.json)
        }
        guard let shot = library.shots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            fail("no Shot named \(name)", json: options.json)
        }
        targets = [shot]
    }
    guard !targets.isEmpty else {
        if options.json { print(#"{"ok":true,"reports":[]}"#) } else { print("No Shots to verify.") }
        exit(EXIT_SUCCESS)
    }

    let verifier = ShotVerifier(library: library)
    let runtime = options.values["quick"] == nil
    let keepRunning = options.values["keep-running"] != nil
    var reports: [VerificationReport] = []
    for shot in targets {
        if !options.json {
            print("\n\(shot.name)  [\(shot.launchMode.rawValue), \(shot.strategy.rawValue)]")
        }
        let report = verifier.verify(shot, runtime: runtime, keepRunning: keepRunning)
        reports.append(report)
        if !options.json {
            for check in report.checks {
                let detail = check.detail.isEmpty ? "" : "  — \(check.detail)"
                print("  \(check.symbol) \(check.name)\(detail)")
            }
        }
    }

    let failed = reports.filter { !$0.passed }
    if options.json {
        let payload: [String: Any] = [
            "ok": failed.isEmpty,
            "reports": reports.map { report in
                [
                    "shot": report.shotName,
                    "passed": report.passed,
                    "checks": report.checks.map {
                        ["name": $0.name, "outcome": $0.outcome.rawValue, "detail": $0.detail]
                    },
                ]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } else {
        print("")
        if failed.isEmpty {
            print("\(reports.count) Shot(s) verified — all checks passed.")
        } else {
            print("\(failed.count) of \(reports.count) Shot(s) failed:")
            for report in failed {
                for check in report.failures { print("  \(report.shotName): \(check.name) — \(check.detail)") }
            }
        }
    }
    if !failed.isEmpty { exit(EXIT_FAILURE) }

case "regenerate":
    let library = ShotLibrary()
    let all = options.values["all"] != nil
    let targets: [Shot]
    if all {
        targets = library.shots
    } else {
        guard let name = options.positional.first else { fail("regenerate needs a Shot name or --all", json: options.json) }
        guard let shot = library.shots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            fail("no Shot named \(name)", json: options.json)
        }
        targets = [shot]
    }
    var rebuilt = 0
    var skipped: [String] = []
    for shot in targets {
        library.regenerate(shot, force: options.values["force"] != nil)
        if library.lastError == nil {
            rebuilt += 1
        } else {
            skipped.append("\(shot.name): \(library.lastError ?? "")")
            library.lastError = nil
        }
    }
    if options.json {
        let payload: [String: Any] = ["ok": skipped.isEmpty, "regenerated": rebuilt, "skipped": skipped]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } else {
        print("Regenerated \(rebuilt) Shot(s)")
        for line in skipped { print("  skipped \(line)") }
    }
    if !skipped.isEmpty { exit(EXIT_FAILURE) }

case "uninstall":
    let library = ShotLibrary()
    let keepData = options.values["keep-data"] != nil
    let keepApp = options.values["keep-app"] != nil
    let dryRun = options.values["dry-run"] != nil

    let uninstaller = Uninstaller(shots: library.shots, keepData: keepData,
                                  removeApplication: !keepApp)
    let plan = uninstaller.plan()

    if options.json {
        var payload: [String: Any] = [
            "ok": true,
            "dryRun": dryRun,
            "totalBytes": plan.totalBytes,
            "items": plan.items.map { ["kind": $0.kind.rawValue, "path": $0.path,
                                       "bytes": $0.bytes, "description": $0.describedAs] },
            "skipped": plan.skipped,
        ]
        if plan.isEmpty { payload["note"] = "nothing to remove" }
        if !dryRun && !options.yes {
            fail("uninstall needs --yes when used with --json", json: true)
        }
        if !dryRun {
            let failures = uninstaller.removeEverything(plan)
            payload["ok"] = failures.isEmpty
            payload["failures"] = failures
        }
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit(EXIT_SUCCESS)
    }

    guard !plan.isEmpty else {
        print("Nothing to remove — Doppio does not appear to be installed.")
        exit(EXIT_SUCCESS)
    }

    print("This will remove:\n")
    for item in plan.items {
        let size = item.bytes > 0 ? "  (\(Uninstaller.humanBytes(item.bytes)))" : ""
        print("  \(item.describedAs)\(size)")
        print("    \(item.path)")
    }
    print("\nTotal: \(Uninstaller.humanBytes(plan.totalBytes))")
    if !plan.skipped.isEmpty {
        print("\nLeft alone (outside Doppio's own folders — yours to remove if you want):")
        for path in plan.skipped { print("  \(path)") }
    }
    if keepData { print("\nKeeping all Shot data and settings (--keep-data).") }
    if keepApp { print("Keeping Doppio.app (--keep-app).") }

    if dryRun {
        print("\nDry run — nothing was removed.")
        exit(EXIT_SUCCESS)
    }

    if !options.yes {
        print("\nThis cannot be undone. Remove all of it? [y/N] ", terminator: "")
        guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
            print("Cancelled. Nothing was removed.")
            exit(EXIT_SUCCESS)
        }
    }

    // Running Shots would be deleted from under themselves.
    for shot in library.shots where library.runState(of: shot) == .running {
        print("Quitting \(shot.name)…")
        library.quit(shot)
    }

    let failures = uninstaller.removeEverything(plan)
    if failures.isEmpty {
        print("\nDone. Doppio has been removed.")
    } else {
        print("\n\(failures.count) item(s) could not be removed:")
        for failure in failures { print("  \(failure)") }
        exit(EXIT_FAILURE)
    }

case "doctor":
    let library = ShotLibrary()
    let shots = library.shots
    var problems: [String] = []
    if !library.forgeAvailable {
        problems.append("the launcher stub is missing — reinstall Doppio")
    }
    for shot in shots {
        let health = library.health(of: shot)
        switch health {
        case .ok: break
        case .bundleMissing: problems.append("\(shot.name): bundle missing from ~/Applications/Doppio")
        case .targetMissing(let id): problems.append("\(shot.name): original app \(id) is not installed")
        case .staleStub: problems.append("\(shot.name): built with an older stub — run doppio regenerate")
        case .staleClone(let old, let new):
            problems.append("\(shot.name): cloned from version \(old) but the app is now \(new) — run doppio regenerate")
        case .selfUpdated:
            problems.append("\(shot.name): the app inside this Shot updated itself and overwrote Doppio's launcher — run doppio regenerate")
        }
    }
    if options.json {
        let data = try! JSONSerialization.data(withJSONObject: [
            "ok": problems.isEmpty, "shots": shots.count, "problems": problems,
        ], options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } else {
        print("Shots:      \(shots.count)")
        print("Stub:       \(library.forgeAvailable ? "ok (v\(DoppioPaths.stubVersion))" : "MISSING")")
        print("Rules:      \(library.compat.rules.count)")
        print("Shots dir:  \(DoppioPaths.shotsDirectory.path)")
        if problems.isEmpty {
            print("\nEverything looks healthy.")
        } else {
            print("\n\(problems.count) problem(s):")
            for problem in problems { print("  - \(problem)") }
        }
    }

default:
    fail("unknown command “\(command)”. Try: doppio help", json: options.json)
}
}

MainActor.assumeIsolated { runCLI() }

extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
