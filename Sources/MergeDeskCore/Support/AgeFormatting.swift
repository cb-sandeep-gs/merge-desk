import Foundation

/// Compact ages for tables ("now", "5h", "3d", "6w", "4mo", "2y"). Fixed thresholds, so the CLI and the app
/// round the same way.
public enum AgeFormatting {
    private static let minute: TimeInterval = 60
    private static let hour = 60 * minute
    private static let day = 24 * hour
    private static let week = 7 * day
    /// 30-day months and 365-day years: precise enough for "how old is this branch".
    private static let month = 30 * day
    private static let year = 365 * day
    private static let weeksBeforeMonths = 8

    public static func short(from date: Date, to now: Date) -> String {
        let age = max(0, now.timeIntervalSince(date))
        switch age {
        case ..<hour: return "now"
        case ..<day: return "\(Int(age / hour))h"
        case ..<week: return "\(Int(age / day))d"
        case ..<(TimeInterval(weeksBeforeMonths) * week): return "\(Int(age / week))w"
        case ..<year: return "\(Int(age / month))mo"
        default: return "\(Int(age / year))y"
        }
    }
}
