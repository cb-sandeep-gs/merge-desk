# Merge Desk — working rules

Plan and phase status: [docs/PLAN.md](docs/PLAN.md). Work one phase (MD-n) at a time; each phase ends with tests
and docs.

## Code
- **MergeDeskCore holds all logic.** The CLI and (from MD-1) the SwiftUI app stay thin layers over it.
- **Git only through `GitClient`.** Add a `GitQuery` (argv + parser together) for every new git call. argv lists
  only, never a shell string. Parse `-z` / porcelain output only, never human-readable text.
- **Never touch the user's checkout.** Writes happen in Merge Desk's own worktrees; every ref move has a backup ref
  under `MergeDeskConstants.backupRefNamespace` and an `AuditLog` entry.
- **Nothing repo-specific in code.** Repository differences belong in `.mergedesk.json` (`RepoConfig`). When a
  config key changes, update `RepoConfig`, `ConfigLoader.validate`, `docs/mergedesk.schema.json` and the README table together.
- **No magic numbers or strings:** use `MergeDeskConstants` or a named constant next to its use.
- Swift 6 language mode, strict concurrency. No new dependencies without discussion (only swift-argument-parser today).
- Comment the why, briefly.

## Tests
- XCTest. Parsers get byte-level tests; behaviour against git gets a fixture in `FixturePattern`.
- Fixtures must stay deterministic (`FixtureBuilder.isolatedEnvironment`, fixed dates).

## Verify before handing over
```bash
swift build && swift test && swiftlint lint --strict
```

## Git
- Conventional Commits (`feat(core): …`), no AI/tool attribution trailers.
- Don't commit, push or change branches unless the user asks.
