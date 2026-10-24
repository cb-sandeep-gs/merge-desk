import Foundation

/// The little the app remembers per repository (e.g. the last view). `UserDefaults` in the app; an in-memory store
/// in tests, so tests never write the user's preferences.
public protocol PreferenceStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// Preferences kept in memory only.
public final class MemoryPreferenceStore: PreferenceStore {
    private var values: [String: Any] = [:]

    public init() {}

    public func string(forKey key: String) -> String? { values[key] as? String }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
}
