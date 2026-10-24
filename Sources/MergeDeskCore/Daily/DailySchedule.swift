import Foundation

/// When the daily job runs.
public struct DailyTime: Sendable, Equatable, Codable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public static let hoursPerDay = 24
    public static let minutesPerHour = 60
    /// The agreed default (PLAN.md §6.7): 09:30, before stand-up.
    public static let defaultDailyRun = DailyTime(checkedHour: 9, minute: 30)

    public init?(hour: Int, minute: Int) {
        guard (0..<Self.hoursPerDay).contains(hour), (0..<Self.minutesPerHour).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// For literals known to be valid.
    private init(checkedHour hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Parses "HH:MM" (24-hour).
    public init?(_ text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public var description: String { String(format: "%02d:%02d", hour, minute) }
}

public enum DailyScheduleError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case launchctlFailed(String)

    public var description: String {
        switch self {
        case let .launchctlFailed(message): return "launchctl failed: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// The installed schedule, read back from the LaunchAgent.
public struct InstalledSchedule: Sendable, Equatable {
    public let time: DailyTime
    public let programArguments: [String]
}

/// Installs the daily job as a per-user LaunchAgent (`~/Library/LaunchAgents`). launchd runs a missed job when the
/// Mac wakes, so a laptop that was asleep at 09:30 still gets its digest. Nothing runs as root.
public struct DailySchedule: Sendable {
    public static let label = "com.cricbuzz.mergedesk.daily"
    static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl")
    static let logFileName = "daily.log"

    private enum PlistKey {
        static let label = "Label"
        static let programArguments = "ProgramArguments"
        static let calendar = "StartCalendarInterval"
        static let hour = "Hour"
        static let minute = "Minute"
        static let standardOut = "StandardOutPath"
        static let standardError = "StandardErrorPath"
        static let environment = "EnvironmentVariables"
        static let runAtLoad = "RunAtLoad"
    }

    public let plistURL: URL
    private let paths: SupportPaths
    /// False in tests: write and read the plist without registering it with launchd.
    private let usesLaunchctl: Bool

    public init(
        launchAgentsFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
        paths: SupportPaths = SupportPaths(),
        usesLaunchctl: Bool = true
    ) {
        self.plistURL = launchAgentsFolder.appendingPathComponent("\(Self.label).plist")
        self.paths = paths
        self.usesLaunchctl = usesLaunchctl
    }

    /// Writes the LaunchAgent and (re)loads it. `program` is the full argv: the executable and its arguments.
    public func install(program: [String], at time: DailyTime) async throws {
        let logURL = paths.root.appendingPathComponent(Self.logFileName)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            PlistKey.label: Self.label,
            PlistKey.programArguments: program,
            PlistKey.calendar: [PlistKey.hour: time.hour, PlistKey.minute: time.minute],
            PlistKey.standardOut: logURL.path,
            PlistKey.standardError: logURL.path,
            PlistKey.runAtLoad: false,
        ]
        // Carry a custom support folder into the job, so it writes where the app reads.
        if let override = ProcessInfo.processInfo.environment[SupportPaths.rootOverrideVariable] {
            plist[PlistKey.environment] = [SupportPaths.rootOverrideVariable: override]
        }
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        guard usesLaunchctl else { return }
        // Replace any loaded copy; "not loaded" is expected on first install, so its failure is ignored.
        _ = try? await launchctl(["bootout", domain, plistURL.path])
        let result = try await launchctl(["bootstrap", domain, plistURL.path])
        guard result.exitCode == GitExitCode.success else { throw DailyScheduleError.launchctlFailed(result.errorText) }
    }

    /// Unloads and deletes the LaunchAgent; nothing to do if it isn't installed.
    public func remove() async throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        if usesLaunchctl { _ = try? await launchctl(["bootout", domain, plistURL.path]) }
        try FileManager.default.removeItem(at: plistURL)
    }

    /// Runs the job now through launchd (same environment as the scheduled run).
    public func runNow() async throws {
        let result = try await launchctl(["kickstart", "\(domain)/\(Self.label)"])
        guard result.exitCode == GitExitCode.success else { throw DailyScheduleError.launchctlFailed(result.errorText) }
    }

    public func installed() -> InstalledSchedule? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let calendar = plist[PlistKey.calendar] as? [String: Int],
              let hour = calendar[PlistKey.hour], let minute = calendar[PlistKey.minute],
              let time = DailyTime(hour: hour, minute: minute) else { return nil }
        return InstalledSchedule(time: time, programArguments: plist[PlistKey.programArguments] as? [String] ?? [])
    }

    public var logURL: URL { paths.root.appendingPathComponent(Self.logFileName) }

    /// The logged-in user's launchd domain.
    private var domain: String { "gui/\(getuid())" }

    private func launchctl(_ arguments: [String]) async throws -> GitResult {
        try await ProcessRunner.run(executableURL: Self.launchctlURL, arguments: arguments,
                                    directory: FileManager.default.temporaryDirectory,
                                    environment: ProcessInfo.processInfo.environment)
    }
}
