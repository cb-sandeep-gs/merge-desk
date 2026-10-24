import Foundation
import MergeDeskCore
import UserNotifications

/// macOS notifications attributed to Merge Desk (clicking one opens the app). Needs the app bundle; when there is
/// none (bare `swift run`) or permission was refused, falls back to AppleScript so the message still shows.
public struct UserNotificationNotifier: Notifier {
    public init() {}

    public func notify(title: String, body: String) async {
        guard Bundle.main.bundleIdentifier != nil, await Self.isAuthorized() else {
            await AppleScriptNotifier().notify(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            await AppleScriptNotifier().notify(title: title, body: body)
        }
    }

    /// Asks once (the system remembers the answer); afterwards just reads the setting.
    public static func isAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }
}

/// The scheduled job: `MergeDesk --daily` runs the daily job for every added repository, then exits.
public enum HeadlessDaily {
    public static func run() async -> Int32 {
        let repositories: [RegisteredRepository]
        do {
            repositories = try RepositoryRegistry().load()
        } catch {
            print("Merge Desk daily: can't read repositories: \(error.localizedDescription)")
            return EXIT_FAILURE
        }
        var failed = false
        for repository in repositories {
            do {
                let result = try await DailyRunner(notifier: UserNotificationNotifier()).run(repositoryRoot: repository.url)
                let count = result.digest.newConflicts.count
                print("Merge Desk daily: \(repository.displayName): \(count) new conflicts → \(result.markdownURL.path)")
            } catch {
                // One broken repository must not stop the others.
                print("Merge Desk daily: \(repository.displayName): \(error.localizedDescription)")
                failed = true
            }
        }
        return failed ? EXIT_FAILURE : EXIT_SUCCESS
    }
}
