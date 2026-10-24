import Foundation

/// Every screen's async data goes through these four states, so loading, empty and error are always handled.
public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    /// Human-readable message, ready to show.
    case failed(String)

    public var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

/// One line for the UI. MergeDeskCore errors are `LocalizedError`s, so this is their own description.
enum ErrorText {
    static func message(_ error: Error) -> String {
        error.localizedDescription
    }
}
