import AppKit
import MergeDeskCore
import SwiftUI

/// Settings ▸ Daily run: turn the schedule on/off, pick the time, run it now.
public struct ScheduleSettingsView: View {
    @Bindable private var schedule: ScheduleModel
    @State private var notificationsAllowed: Bool?

    public init(schedule: ScheduleModel) {
        self.schedule = schedule
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Run the daily digest every day", isOn: Binding(
                    get: { schedule.isEnabled },
                    set: { enabled in Task { enabled ? await schedule.enable() : await schedule.disable() } }
                ))
                .disabled(schedule.isBusy)
                .accessibilityIdentifier(AccessibilityID.scheduleToggle)
                DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .onChange(of: schedule.time) {
                        // Changing the time of an active schedule re-installs it.
                        if schedule.isEnabled { Task { await schedule.enable() } }
                    }
                Text("Fetches every added repository, predicts every merge and writes the digest. Never merges or pushes. "
                     + "If the Mac is asleep at that time, it runs on wake.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Daily run", systemImage: Symbol.schedule)
            }
            if schedule.pointsElsewhere {
                Label("The schedule points at another copy of Merge Desk. Turn it off and on to use this one.",
                      systemImage: Symbol.warning).foregroundStyle(Palette.conflict)
            }
            if let error = schedule.errorMessage {
                Label(error, systemImage: Symbol.warning).foregroundStyle(Palette.conflict)
            }
            Section("Notifications") {
                LabeledContent("Status", value: notificationsAllowed.map { $0 ? "Allowed" : Self.notificationsOff } ?? "…")
                Button("Allow Notifications") {
                    Task { notificationsAllowed = await UserNotificationNotifier.isAuthorized() }
                }
            }
            Section {
                HStack {
                    Button("Run Now") { Task { await schedule.runNow() } }.disabled(!schedule.isEnabled || schedule.isBusy)
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([schedule.logURL]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
        .task { notificationsAllowed = await UserNotificationNotifier.isAuthorized() }
    }

    private static let notificationsOff = "Off (System Settings ▸ Notifications)"

    /// DatePicker works on `Date`; only hour and minute matter.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: schedule.time.hour, minute: schedule.time.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                if let time = DailyTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0) { schedule.time = time }
            }
        )
    }
}

/// Menu-bar summary of the latest digests.
public struct MenuBarContent: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        if app.repositories.isEmpty {
            Text("No repositories added")
        }
        ForEach(app.digests, id: \.repository.id) { item in
            Section(item.repository.displayName) {
                if let digest = item.digest {
                    Text(MenuBarText.summary(digest))
                    ForEach(digest.newConflicts.prefix(Layout.menuBarDigestLimit)) { conflict in
                        Text("New: \(conflict.key.description) (\(conflict.fileCount) files)")
                    }
                    ForEach(digest.rebaseToday.prefix(Layout.menuBarDigestLimit), id: \.self) { branch in
                        Text("Rebase today: \(branch)")
                    }
                } else {
                    Text("No digest yet")
                }
            }
        }
        Divider()
        Button(app.isRunningDaily ? "Running…" : "Fetch & Run Daily Now") {
            Task { await app.runDailyForAll() }
        }
        .disabled(app.isRunningDaily || app.repositories.isEmpty)
        Button("Open Merge Desk") {
            openWindow(id: MenuBarText.mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Merge Desk") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

public enum MenuBarText {
    /// Window id shared by the app scene and "Open Merge Desk".
    public static let mainWindowID = "main"

    static func summary(_ digest: DailyDigest) -> String {
        let integration = digest.integrationConflicts.count
        let pairs = digest.pairConflicts.count
        let when = digest.generatedAt.formatted(.relative(presentation: .named))
        return "\(digest.newConflicts.count) new · \(integration) vs integration · \(pairs) between branches · \(when)"
    }
}
