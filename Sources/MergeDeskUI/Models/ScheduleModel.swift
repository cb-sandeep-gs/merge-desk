import Foundation
import MergeDeskCore
import Observation

/// The Settings screen's daily-run controls, over `DailySchedule`. The scheduled job runs this app's own
/// executable with `--daily`, so its notifications come from Merge Desk.
@MainActor
@Observable
public final class ScheduleModel {
    /// Argument that starts the app headless for one daily run.
    public static let dailyArgument = "--daily"

    public private(set) var installed: InstalledSchedule?
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false
    /// Time chosen in the picker (applied by `enable`).
    public var time: DailyTime

    private let schedule: DailySchedule
    private let program: [String]

    /// - Parameter executablePath: the binary launchd runs (defaults to this app's executable).
    public init(schedule: DailySchedule = DailySchedule(), executablePath: String? = Bundle.main.executablePath) {
        self.schedule = schedule
        self.program = [executablePath ?? CommandLine.arguments[0], Self.dailyArgument]
        let current = schedule.installed()
        self.installed = current
        self.time = current?.time ?? .defaultDailyRun
    }

    public var isEnabled: Bool { installed != nil }
    public var logURL: URL { schedule.logURL }
    /// The schedule points at a different copy of the app (e.g. after moving it): re-enable to fix.
    public var pointsElsewhere: Bool { installed.map { $0.programArguments != program } ?? false }

    public func enable() async {
        await perform { try await self.schedule.install(program: self.program, at: self.time) }
    }

    public func disable() async {
        await perform { try await self.schedule.remove() }
    }

    public func runNow() async {
        await perform { try await self.schedule.runNow() }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        do {
            try await action()
        } catch {
            errorMessage = ErrorText.message(error)
        }
        installed = schedule.installed()
        isBusy = false
    }
}
