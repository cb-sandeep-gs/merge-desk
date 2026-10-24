import Foundation

// Our errors already describe themselves for people; `LocalizedError` makes `localizedDescription` return that
// text everywhere (SwiftUI alerts, the CLI), instead of "The operation couldn't be completed".
extension GitError: LocalizedError { public var errorDescription: String? { description } }
extension ConfigError: LocalizedError { public var errorDescription: String? { description } }
extension BranchDetailError: LocalizedError { public var errorDescription: String? { description } }
extension RepositoryRegistryError: LocalizedError { public var errorDescription: String? { description } }
extension GlobPattern.CompileError: LocalizedError { public var errorDescription: String? { description } }
