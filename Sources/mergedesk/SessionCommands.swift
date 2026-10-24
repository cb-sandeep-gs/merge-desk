import ArgumentParser
import Foundation
import MergeDeskCore

extension MergeStrategy: ExpressibleByArgument {}

/// Builds a session manager for `--repo` with its config.
private func makeManager(_ repository: RepositoryOptions) async throws -> SessionManager {
    let git = ProcessGitClient()
    let root = try await repository.repositoryRoot(using: git)
    let config = try ConfigLoader.load(repositoryRoot: root).config
    return SessionManager(repositoryRoot: root, config: config, git: git)
}

struct MergeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge a branch into another in an isolated worktree (your checkout is never touched).",
        discussion: """
        Creates a session and runs the merge. Nothing outside Merge Desk changes until `mergedesk session apply`.
        Protected targets (e.g. develop, main) get a new mergedesk/… branch and a pull request instead.
        """
    )

    @OptionGroup var repository: RepositoryOptions
    @Argument(help: "Branch to merge (without the remote).")
    var source: String
    @Option(name: .long, help: "Branch to merge into.")
    var into: String
    @Option(name: .long, help: "merge (merge commit) or squash.")
    var strategy: MergeStrategy = .mergeCommit
    @Flag(name: .long, help: "Don't git fetch before merging.")
    var noFetch = false

    func run() async throws {
        let manager = try await makeManager(repository)
        let planned = try await manager.plan(source: source, target: into, strategy: strategy)
        do {
            let session = try await manager.start(planned.id, fetch: !noFetch)
            print(SessionText.render(session))
        } catch {
            if let session = try? manager.store.load(planned.id) { print(SessionText.render(session)) }
            throw error
        }
    }
}

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "List merge sessions and move one along: continue, apply, push, pr, undo, abort.",
        subcommands: [List.self, Show.self, Continue.self, Apply.self, Push.self, PullRequest.self, Undo.self, Abort.self]
    )

    /// Session id (or the short id from `session list`) plus the repository.
    struct Target: ParsableArguments {
        @OptionGroup var repository: RepositoryOptions
        @Argument(help: "Session id (the short id is enough).")
        var id: String

        func resolve() async throws -> (SessionManager, MergeSession) {
            let manager = try await makeManager(repository)
            guard let session = manager.store.find(id) else { throw ValidationError("No single session matches '\(id)'.") }
            return (manager, session)
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Merge sessions, newest first.")
        @OptionGroup var repository: RepositoryOptions

        func run() async throws {
            let sessions = try await makeManager(repository).store.all()
            if sessions.isEmpty { Report.info("No merge sessions yet (mergedesk merge <branch> --into <target>).") }
            for session in sessions {
                print("\(session.shortID)  \(session.state.title.padding(toLength: 16, withPad: " ", startingAt: 0))"
                      + "\(session.source) → \(session.target)  (\(session.createdAt.formatted(date: .abbreviated, time: .shortened)))")
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "One session in detail.")
        @OptionGroup var target: Target
        func run() async throws { print(SessionText.render(try await target.resolve().1)) }
    }

    struct Continue: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "After editing the conflicts in the worktree: check and commit.")
        @OptionGroup var target: Target
        func run() async throws {
            let (manager, session) = try await target.resolve()
            print(SessionText.render(try await manager.continueAfterResolving(session.id)))
        }
    }

    struct Apply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Point the local branch at the merge (backup ref kept; refused if the branch is checked out or moved)."
        )
        @OptionGroup var target: Target
        func run() async throws {
            let (manager, session) = try await target.resolve()
            print(SessionText.render(try await manager.apply(session.id)))
        }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Push the merged target branch (never forced; protected branches refused)."
        )
        @OptionGroup var target: Target
        @Flag(name: .long, help: "Don't ask for confirmation.")
        var yes = false
        func run() async throws {
            let (manager, session) = try await target.resolve()
            let confirmed = yes || Confirmation.ask("Push \(session.target) to the remote?")
            print(SessionText.render(try await manager.push(session.id, confirmed: confirmed)))
        }
    }

    struct PullRequest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pr",
            abstract: "Push the mergedesk/… branch and open a pull request into the protected target (gh, or the compare page)."
        )
        @OptionGroup var target: Target
        @Flag(name: .long, help: "Don't ask for confirmation.")
        var yes = false
        func run() async throws {
            let (manager, session) = try await target.resolve()
            let branch = session.pullRequestBranch ?? "the branch"
            let confirmed = yes || Confirmation.ask("Push \(branch) and open a pull request into \(session.target)?")
            print(SessionText.render(try await manager.openPullRequest(session.id, confirmed: confirmed)))
        }
    }

    struct Undo: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put the branch back exactly where it was before apply.")
        @OptionGroup var target: Target
        func run() async throws {
            let (manager, session) = try await target.resolve()
            print(SessionText.render(try await manager.undo(session.id)))
        }
    }

    struct Abort: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Give up before apply: remove the worktree.")
        @OptionGroup var target: Target
        func run() async throws {
            let (manager, session) = try await target.resolve()
            print(SessionText.render(try await manager.abort(session.id)))
        }
    }
}

/// Asks on the terminal; anything but "y"/"yes" — or no terminal at all — means no.
enum Confirmation {
    static func ask(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else { return false }
        print("\(question) [y/N] ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}

enum SessionText {
    static func render(_ session: MergeSession) -> String {
        var lines = ["Session \(session.shortID): \(session.source) → \(session.target) (\(session.strategy.title.lowercased()))",
                     "  state      \(session.state.title)"]
        if session.viaPullRequest { lines.append("  route      pull request via \(session.pullRequestBranch ?? "")") }
        if let worktree = session.worktreePath { lines.append("  worktree   \(worktree)") }
        if let result = session.resultID { lines.append("  result     \(result.prefix(10))") }
        if let applied = session.applied { lines.append("  applied    \(applied.branch)") }
        if let url = session.pullRequestURL { lines.append("  pr         \(url)") }
        lines += session.warnings.map { "  ! \($0)" }
        if let error = session.lastError { lines.append("  ✗ \(error)") }
        if !session.conflictedFiles.isEmpty, session.state == .resolving {
            lines.append("  conflicts  edit these in the worktree, then `mergedesk session continue \(session.shortID)`:")
            lines += session.conflictedFiles.map { "             \($0)" }
        }
        if let next = nextStep(session) { lines.append("  next       \(next)") }
        return lines.joined(separator: "\n")
    }

    private static func nextStep(_ session: MergeSession) -> String? {
        let id = session.shortID
        switch session.state {
        case .ready: return "mergedesk session apply \(id)   (or abort \(id))"
        case .applied:
            let verb = session.viaPullRequest ? "pr" : "push"
            return "mergedesk session \(verb) \(id)   (or undo \(id))"
        case .planned, .preflight, .merging, .verifying: return "mergedesk session abort \(id)"
        case .resolving, .pushed, .pullRequestOpened, .aborted, .undone: return nil
        }
    }
}
