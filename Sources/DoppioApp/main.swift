import SwiftUI
import AppKit
import DoppioCore

// Doppio — the generator and library UI.
//
// Built as a plain SwiftUI app; the surrounding .app bundle is assembled by
// scripts/build-app.sh, which also embeds the stub and the CLI.

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS enforces one instance per bundle *path*, not per bundle ID, so
        // a copy in a build directory and an installed copy can both run and
        // then fight over library.json. Hand over to the instance that is
        // already up instead.
        if let existing = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "org.doppio-mac.Doppio")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct DoppioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var library = ShotLibrary()

    var body: some Scene {
        WindowGroup("Doppio") {
            LibraryView()
                .environmentObject(library)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Shot…") {
                    NotificationCenter.default.post(name: .doppioNewShot, object: nil)
                }
                .keyboardShortcut("n")
                Divider()
                Button("Install Command Line Tool…") { CommandLineInstaller.install() }
                Divider()
                Button("Remove Everything…") {
                    NotificationCenter.default.post(name: .doppioUninstall, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let doppioNewShot = Notification.Name("DoppioNewShot")
    static let doppioUninstall = Notification.Name("DoppioUninstall")
}

// SwiftUI's @main cannot be used alongside top-level code in main.swift.
DoppioApp.main()
