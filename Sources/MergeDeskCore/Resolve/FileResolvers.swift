import Foundation

/// The three versions of one conflicted file (nil = the file doesn't exist on that side).
public struct ConflictInput: Sendable {
    public let path: String
    public let base: Data?
    public let ours: Data?
    public let theirs: Data?

    public init(path: String, base: Data?, ours: Data?, theirs: Data?) {
        self.path = path
        self.base = base
        self.ours = ours
        self.theirs = theirs
    }
}

/// What a resolver decided for one file.
public enum ResolverOutcome: Equatable, Sendable {
    /// Content to write (nil = delete the file), how sure, and a one-line explanation.
    case resolved(Data?, Confidence, String)
    /// Take this content now, but the file must be rebuilt by the repository's generator afterwards.
    case regenerate(Data?, command: [String])
    /// A person decides.
    case escalate(String)
}

/// One Tier-1 strategy (PLAN.md §6.4).
public protocol FileResolver: Sendable {
    func resolve(_ input: ConflictInput, git: GitClient) async throws -> ResolverOutcome
}

public enum FileResolvers {
    /// The resolver for a file class rule. `regenerateCommand` is the repo-wide fallback command.
    public static func resolver(for rule: FileClassRule, regenerateCommand: [String]?) -> FileResolver {
        switch rule.strategy {
        case .escalate: return EscalateResolver()
        case .regenerate: return RegenerateResolver(command: rule.command ?? regenerateCommand ?? [])
        case .unionEntries: return UnionEntriesResolver()
        case .jsonKeys: return JSONKeysResolver()
        case .pbxproj: return PBXProjResolver()
        }
    }
}

struct EscalateResolver: FileResolver {
    func resolve(_ input: ConflictInput, git: GitClient) async throws -> ResolverOutcome {
        .escalate("this file class always goes to a person")
    }
}

/// Generated files are never merged by content: keep one side, then the generator rebuilds them from the merged
/// sources. Ours is kept (theirs if ours deleted it); the regenerated result is what gets committed.
struct RegenerateResolver: FileResolver {
    let command: [String]

    func resolve(_ input: ConflictInput, git: GitClient) async throws -> ResolverOutcome {
        guard !command.isEmpty else { return .escalate("no regenerate command configured") }
        return .regenerate(input.ours ?? input.theirs, command: command)
    }
}

/// Changelogs, release notes, lists: keep both sides' new lines. Pure additions on both sides are certain
/// (high); edits of existing lines on one side are likely right (medium); both editing the same line escalates.
struct UnionEntriesResolver: FileResolver {
    func resolve(_ input: ConflictInput, git: GitClient) async throws -> ResolverOutcome {
        guard let ours = input.ours, let theirs = input.theirs else { return .escalate("deleted on one side") }
        let text = try await ConflictedText.make(base: input.base, ours: ours, theirs: theirs, git: git)
        let merge: ConflictedText.BlockResolver = { LineMerge.merge(base: $1, ours: $0, theirs: $2) }
        guard let resolved = text.resolved(merge) else {
            return .escalate(text.firstConflictReason(merge) ?? "overlapping edits")
        }
        return .resolved(Data(resolved.text.utf8), resolved.pureInsertion ? .high : .medium,
                         resolved.pureInsertion ? "kept both sides' new entries" : "kept both sides' entries (one side also edited)")
    }
}

/// JSON merged key by key; same-key edits escalate. The output keeps ours' key order and layout.
struct JSONKeysResolver: FileResolver {
    func resolve(_ input: ConflictInput, git: GitClient) async throws -> ResolverOutcome {
        guard let oursData = input.ours, let theirsData = input.theirs else { return .escalate("deleted on one side") }
        let ours: OrderedJSON, theirs: OrderedJSON, base: OrderedJSON?
        do {
            ours = try OrderedJSON(parsing: oursData)
            theirs = try OrderedJSON(parsing: theirsData)
            base = try input.base.map { try OrderedJSON(parsing: $0) }
        } catch {
            return .escalate("not valid JSON on one side")
        }
        do {
            guard let merged = try OrderedJSON.merge(base: base, ours: ours, theirs: theirs) else {
                return .resolved(nil, .high, "deleted on both sides")
            }
            // Untouched ours keeps its exact bytes; otherwise write in ours' style.
            if merged == ours { return .resolved(oursData, .high, "kept ours (theirs changed nothing else)") }
            let style = JSONStyle.detect(String(decoding: oursData, as: UTF8.self))
            return .resolved(Data(merged.serialized(style).utf8), .high, "merged JSON keys from both sides")
        } catch let conflict as JSONMergeConflict {
            return .escalate("both sides changed \(conflict.path)")
        }
    }
}

/// Xcode projects: the line merge (both sides' additions kept), then two safety nets — no key may end up
/// assigned two different values, and the result must still be a valid project whose every object reference
/// resolves. Anything else escalates.
struct PBXProjResolver: FileResolver {
    func resolve(_ input: ConflictInput, git: GitClient) async throws -> ResolverOutcome {
        guard let ours = input.ours, let theirs = input.theirs else { return .escalate("project deleted on one side") }
        let text = try await ConflictedText.make(base: input.base, ours: ours, theirs: theirs, git: git)
        let merge: ConflictedText.BlockResolver = { oursLines, baseLines, theirsLines in
            let result = LineMerge.merge(base: baseLines, ours: oursLines, theirs: theirsLines)
            guard case let .merged(lines, _) = result else { return result }
            let clashes = LineMerge.conflictingAssignments(lines)
            return clashes.isEmpty ? result : .conflict("both sides set \(clashes.joined(separator: ", "))")
        }
        guard let resolved = text.resolved(merge) else {
            return .escalate(text.firstConflictReason(merge) ?? "overlapping edits")
        }
        let data = Data(resolved.text.utf8)
        if let problem = await PBXProjValidator.problem(in: data, comparedWith: ours) {
            return .escalate(problem)
        }
        return .resolved(data, resolved.pureInsertion ? .high : .medium,
                         resolved.pureInsertion ? "kept both sides' project additions (validated)" : "merged project edits (validated)")
    }
}

/// Checks a merged project.pbxproj: it parses (via `plutil`), and it references no object id that doesn't
/// exist — beyond any dangling references ours already had.
public enum PBXProjValidator {
    static let plutil = URL(fileURLWithPath: "/usr/bin/plutil")
    static let objectsKey = "objects"
    /// Xcode object ids: 24 uppercase hex characters.
    static let objectIDLength = 24

    public static func problem(in merged: Data, comparedWith ours: Data) async -> String? {
        guard let mergedObjects = await objects(merged) else { return "merged project doesn't parse" }
        let oursObjects = await objects(ours) ?? [:]
        let newDangling = dangling(mergedObjects).subtracting(dangling(oursObjects))
        guard newDangling.isEmpty else {
            return "merged project references \(newDangling.count) missing object(s), e.g. \(newDangling.sorted().first ?? "")"
        }
        return nil
    }

    /// The `objects` dictionary, read through `plutil -convert json` (handles the old-style plist format).
    static func objects(_ data: Data) async -> [String: Any]? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mergedesk-pbx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let file = folder.appendingPathComponent("project.pbxproj")
        guard (try? data.write(to: file)) != nil,
              let result = try? await ProcessRunner.run(executableURL: plutil, arguments: ["-convert", "json", "-o", "-", file.path],
                                                        directory: folder, environment: ProcessInfo.processInfo.environment),
              result.exitCode == GitExitCode.success,
              let root = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any] else { return nil }
        return root[objectsKey] as? [String: Any]
    }

    /// Object ids referenced anywhere in object values but not defined.
    static func dangling(_ objects: [String: Any]) -> Set<String> {
        var referenced = Set<String>()
        func collect(_ value: Any) {
            switch value {
            case let text as String where isObjectID(text): referenced.insert(text)
            case let list as [Any]: list.forEach(collect)
            case let dictionary as [String: Any]: dictionary.values.forEach(collect)
            default: break
            }
        }
        objects.values.forEach(collect)
        return referenced.subtracting(objects.keys)
    }

    static func isObjectID(_ text: String) -> Bool {
        text.count == objectIDLength && text.allSatisfy { $0.isHexDigit && !$0.isLowercase }
    }
}
