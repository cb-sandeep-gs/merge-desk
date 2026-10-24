import Foundation

/// What happened. A struct (not an enum) so logs written by a newer version still decode in an older one.
public struct AuditAction: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let sessionPlanned = AuditAction(rawValue: "session.planned")
    public static let backupCreated = AuditAction(rawValue: "backup.created")
    public static let mergeApplied = AuditAction(rawValue: "merge.applied")
    public static let mergeAborted = AuditAction(rawValue: "merge.aborted")
    public static let mergeUndone = AuditAction(rawValue: "merge.undone")
    public static let fileResolved = AuditAction(rawValue: "file.resolved")
    public static let branchPushed = AuditAction(rawValue: "branch.pushed")
    public static let pullRequestOpened = AuditAction(rawValue: "pr.opened")
    public static let branchDeleted = AuditAction(rawValue: "branch.deleted")
}

/// One line of the audit log.
public struct AuditEvent: Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    /// macOS user who triggered the action.
    public let user: String
    public let action: AuditAction
    public let branch: String?
    public let objectIDBefore: String?
    public let objectIDAfter: String?
    public let backupRef: String?
    /// Free-form extras (tier, confidence, file path, session id …), kept flat so the log stays greppable.
    public let details: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        user: String = NSUserName(),
        action: AuditAction,
        branch: String? = nil,
        objectIDBefore: String? = nil,
        objectIDAfter: String? = nil,
        backupRef: String? = nil,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.user = user
        self.action = action
        self.branch = branch
        self.objectIDBefore = objectIDBefore
        self.objectIDAfter = objectIDAfter
        self.backupRef = backupRef
        self.details = details
    }
}

/// Events read back, plus how many lines could not be decoded (a crash mid-write, or hand edits).
public struct AuditLogContents: Sendable, Equatable {
    public let events: [AuditEvent]
    public let unreadableLineCount: Int
}

/// Append-only JSON Lines log, one per repository. An actor so concurrent appends from the app and a
/// background job in the same process never interleave.
public actor AuditLog {
    nonisolated public let fileURL: URL
    private let fileManager: FileManager
    private static let newline = UInt8(ascii: "\n")

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func append(_ event: AuditEvent) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }

        let end = try handle.seekToEnd()
        var line = Data()
        // If a previous write was cut off mid-line, start on a fresh line so this event stays readable.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.first != Self.newline { line.append(Self.newline) }
            try handle.seekToEnd()
        }
        line.append(try Self.encoder.encode(event))
        line.append(Self.newline)
        try handle.write(contentsOf: line)
        // The log is the record of what changed in someone's repository; make sure it reaches the disk.
        try handle.synchronize()
    }

    /// Reads every event; a missing file is an empty log.
    public func readAll() throws -> AuditLogContents {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return AuditLogContents(events: [], unreadableLineCount: 0)
        }
        let data = try Data(contentsOf: fileURL)
        var events: [AuditEvent] = []
        var unreadable = 0
        for line in data.split(separator: Self.newline, omittingEmptySubsequences: true) {
            if let event = try? Self.decoder.decode(AuditEvent.self, from: Data(line)) {
                events.append(event)
            } else {
                unreadable += 1
            }
        }
        return AuditLogContents(events: events, unreadableLineCount: unreadable)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Sorted keys keep lines diff-friendly; no pretty printing — one event per line.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
