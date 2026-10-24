import AppKit
import MergeDeskUI
import SwiftUI

/// App entry point only; everything else lives in MergeDeskUI (testable) and MergeDeskCore.
@main
struct MergeDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Merge Desk") {
            MergeDeskRootView(app: model)
        }
        .defaultSize(width: Layout.windowDefaultWidth, height: Layout.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Branches") { model.selectedModel?.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.selectedModel == nil)
            }
        }
    }
}

/// Makes the app a regular foreground app even when launched as a bare SwiftPM executable (`swift run`),
/// and quits when the last window closes (a single-window tool).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
