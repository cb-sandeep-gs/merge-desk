import ArgumentParser
import Foundation
import MergeDeskCore
import MergeDeskFixtures

/// `mergedesk` — the command-line face of MergeDeskCore. Later phases add list / predict / merge / daily here.
@main
struct MergeDeskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mergedesk",
        abstract: "Branch dashboard, merge planner and history-aware conflict resolver for git repositories.",
        version: MergeDeskConstants.toolVersion,
        subcommands: [ListCommand.self, ShowCommand.self, DoctorCommand.self, ConfigCommand.self, FixturesCommand.self, VersionCommand.self]
    )
}

/// Options shared by every command that works on one repository.
struct RepositoryOptions: ParsableArguments {
    @Option(name: .long, help: "Repository folder (default: current directory).")
    var repo: String?

    /// Resolves `--repo` (or the current directory) to the repository's top-level folder.
    func repositoryRoot(using git: GitClient) async throws -> URL {
        let start = CommandPath.absoluteDirectory(repo ?? FileManager.default.currentDirectoryPath)
        do {
            return try await git.execute(.repositoryRoot, in: start)
        } catch {
            throw ValidationError("\(start.path) is not inside a git repository (\(error)).")
        }
    }
}

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Show Merge Desk and git versions.")

    func run() async throws {
        print("mergedesk \(MergeDeskConstants.toolVersion)")
        let version = try await ProcessGitClient().execute(.version, in: URL(fileURLWithPath: NSTemporaryDirectory()))
        print("git \(version)")
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that git, the repository and its .mergedesk.json are ready for Merge Desk."
    )

    @OptionGroup var repository: RepositoryOptions

    func run() async throws {
        let git = ProcessGitClient()
        var problems = 0

        let version = try await git.execute(.version, in: URL(fileURLWithPath: NSTemporaryDirectory()))
        if version >= MergeDeskConstants.minimumGitVersion {
            Report.ok("git \(version) (\(git.executableURL.path))")
        } else {
            Report.fail("git \(version) is older than \(MergeDeskConstants.minimumGitVersion), needed for conflict prediction")
            problems += 1
        }

        let root = try await repository.repositoryRoot(using: git)
        Report.ok("repository \(root.path)")

        do {
            let loaded = try ConfigLoader.load(repositoryRoot: root)
            switch loaded.source {
            case let .file(url): Report.ok("config \(url.lastPathComponent) is valid")
            case .defaults: Report.info("no \(MergeDeskConstants.configFileName); built-in defaults apply (run `mergedesk config init`)")
            }
            loaded.warnings.forEach { Report.warn($0.description) }
            let branches = try await git.execute(.branches(), in: root)
            for name in loaded.config.integrationBranches where !branches.contains(where: { $0.branchName == name }) {
                Report.warn("integration branch '\(name)' does not exist locally or on any remote")
            }
            Report.ok("\(branches.count) branches (local + remote-tracking)")
        } catch let error as ConfigError {
            Report.fail(error.description)
            problems += 1
        }

        Report.info("support folder \(SupportPaths().repositoryFolder(for: root).path)")
        if problems > 0 { throw ExitCode.failure }
    }
}

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect, validate or create a repository's .mergedesk.json.",
        subcommands: [Validate.self, Show.self, Init.self]
    )

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Validate .mergedesk.json (or any file with --file).")

        @OptionGroup var repository: RepositoryOptions
        @Option(name: .long, help: "Validate this file instead of the repository's .mergedesk.json.")
        var file: String?

        func run() async throws {
            do {
                if let file {
                    let url = URL(fileURLWithPath: file)
                    let (_, warnings) = try ConfigLoader.decode(try Data(contentsOf: url), path: url.path)
                    warnings.forEach { Report.warn($0.description) }
                    Report.ok("\(url.path) is valid")
                    return
                }
                let root = try await repository.repositoryRoot(using: ProcessGitClient())
                let loaded = try ConfigLoader.load(repositoryRoot: root)
                loaded.warnings.forEach { Report.warn($0.description) }
                switch loaded.source {
                case let .file(url): Report.ok("\(url.path) is valid")
                case .defaults: Report.info("no \(MergeDeskConstants.configFileName) in \(root.path); defaults apply")
                }
            } catch let error as ConfigError {
                Report.fail(error.description)
                throw ExitCode.failure
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the configuration in force (file merged with defaults).")

        @OptionGroup var repository: RepositoryOptions

        func run() async throws {
            let root = try await repository.repositoryRoot(using: ProcessGitClient())
            let loaded = try ConfigLoader.load(repositoryRoot: root)
            print(String(decoding: try ConfigJSON.encode(loaded.config), as: UTF8.self))
        }
    }

    struct Init: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a .mergedesk.json with the defaults, to edit and commit.")

        @OptionGroup var repository: RepositoryOptions
        @Flag(name: .long, help: "Replace an existing .mergedesk.json.")
        var force = false

        func run() async throws {
            let root = try await repository.repositoryRoot(using: ProcessGitClient())
            let url = root.appendingPathComponent(MergeDeskConstants.configFileName)
            if FileManager.default.fileExists(atPath: url.path), !force {
                throw ValidationError("\(url.path) already exists; pass --force to replace it.")
            }
            try ConfigJSON.encode(RepoConfig.defaults).write(to: url, options: .atomic)
            Report.ok("wrote \(url.path)")
        }
    }
}

struct FixturesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fixtures",
        abstract: "Build the scripted conflict-pattern repositories used by the tests, to inspect them by hand.",
        subcommands: [Build.self, List.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List fixture patterns and what each expects.")

        func run() async throws {
            for pattern in FixturePattern.allCases {
                let definition = pattern.definition
                let conflicts = definition.expectedConflicts.isEmpty ? "clean" : definition.expectedConflicts.joined(separator: ", ")
                print(pattern.rawValue)
                print("  merge \(definition.sourceBranch) → \(definition.targetBranch): \(conflicts)")
                print("  expected: \(definition.expectedResolution)")
            }
        }
    }

    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create fixture repositories in a new folder.")

        @Argument(help: "Folder to create the fixtures in (each pattern becomes a sub-folder).")
        var output: String
        @Option(name: .long, help: "Only this pattern (repeatable). Default: all.")
        var pattern: [String] = []

        func run() async throws {
            let parent = CommandPath.absoluteDirectory(output)
            let patterns = try pattern.isEmpty ? FixturePattern.allCases : pattern.map { name in
                guard let match = FixturePattern(rawValue: name) else {
                    throw ValidationError("unknown pattern '\(name)'; see `mergedesk fixtures list`")
                }
                return match
            }
            let builder = FixtureBuilder()
            for pattern in patterns {
                let fixture = try await builder.build(pattern, in: parent)
                Report.ok("\(fixture.url.path)  (\(fixture.definition.sourceBranch) → \(fixture.definition.targetBranch))")
            }
        }
    }
}

/// Turns user-typed paths (often relative, e.g. `../repo`) into absolute file URLs; `Process` needs absolute
/// working directories.
enum CommandPath {
    static func absoluteDirectory(_ path: String) -> URL {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: currentDirectory).absoluteURL.standardizedFileURL
    }
}

/// Pretty, stable JSON for config files people read and commit.
enum ConfigJSON {
    static func encode(_ config: RepoConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config) + Data("\n".utf8)
    }
}

/// Consistent one-line status output for every command.
enum Report {
    static func ok(_ message: String) { print("✓ \(message)") }
    static func info(_ message: String) { print("• \(message)") }
    static func warn(_ message: String) { print("! \(message)") }
    static func fail(_ message: String) {
        FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    }
}
