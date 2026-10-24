import AppKit
import MergeDeskUI
import SwiftUI

/// The app's scenes; everything else lives in MergeDeskUI (testable) and MergeDeskCore.
struct MergeDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var schedule = ScheduleModel()

    var body: some Scene {
        Window("Merge Desk", id: MenuBarText.mainWindowID) {
            MergeDeskRootView(app: model)
        }
        .defaultSize(width: Layout.windowDefaultWidth, height: Layout.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Branches") { model.selectedModel?.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.selectedModel == nil)
                Button("Fetch & Run Daily Digest") { Task { await model.runDailyForAll() } }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.isRunningDaily || model.repositories.isEmpty)
            }
        }

        Settings {
            ScheduleSettingsView(schedule: schedule)
        }

        // The badge shows new conflicts from the latest digests.
        MenuBarExtra {
            MenuBarContent(app: model)
        } label: {
            Label("Merge Desk", systemImage: model.newConflictCount > 0 ? "arrow.triangle.merge" : "arrow.triangle.branch")
        }
    }
}

/// Makes the app a regular foreground app even when launched as a bare SwiftPM executable (`swift run`).
/// It keeps running after the window closes so the menu-bar extra stays available.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
