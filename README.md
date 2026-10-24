# Merge Desk

A macOS app and CLI for any Cricbuzz git repository. It lists every branch with its health, predicts conflicts
before anyone merges, runs merges safely, and resolves conflicts from file-type rules and **git history** — with
evidence and a confidence score for every decision.

> **Status: MD-4 (automatic file-rule resolution).** Predict every merge (`git merge-tree`), get a daily digest, and run merges
> safely: each merge happens in its own worktree, Apply moves a branch only by compare-and-swap with a backup ref,
> Undo restores the exact commit, pushes need confirmation and protected branches only get pull requests.
> Conflicts in classified files (Xcode projects, generated files, JSON, changelogs) and conflicts resolved before
> (rerere) are resolved automatically and scored against your own history with `mergedesk eval`.
> The history engine for everything else arrives in MD-5 — see [docs/PLAN.md](docs/PLAN.md).

## Requirements

- macOS 14+, Xcode 16+ (Swift 6 toolchain)
- git 2.38+ (`git merge-tree --write-tree`); `mergedesk doctor` checks this

## Build, test, run

```bash
swift build
swift test
swift run mergedesk --help
./Scripts/build-app.sh          # → .build/MergeDesk.app (ad-hoc signed, for local use)
open .build/MergeDesk.app
```

## The app

Add a repository with **+** (any folder inside a clone; the folder is never modified). The window has three panes:

- **Repositories** — everything you added; right-click to reveal in Finder or remove.
- **Branches** — one row per branch name (local and remote copies merged), with where it lives, last commit,
  author, ahead/behind against the first two integration branches, and badges (Integration, Protected, Stale,
  Merged, Never pushed, N unpushed, N to pull). Filter with **All · Mine · Active · Stale · Merged · Unpushed**, a
  branch-name prefix, or search by branch or author; click a column to sort; ⌘R refreshes.
- **Conflict Matrix** — active branches × active branches; each cell is the number of files that would conflict
  if the two were merged (click for the files and how each would be resolved). Up to 40 most recent active branches.
- **Daily Digest** — what needs attention today: your branches to rebase, new and resolved conflicts since the last
  run, every predicted conflict with each integration branch and between branches, drifting, stale and merged
  branches. **Fetch & Run Now** runs it on demand.
- **Merges** — merge sessions, newest first. Select a branch and choose **Merge…** (target, merge commit or squash,
  fetch first, and a conflict preview). The merge runs in a separate worktree; then, step by step:
  **Mark Resolved & Continue** (after editing conflicts in the worktree) → **Apply** (moves the local branch, with a
  backup ref) → **Push…** or, for protected targets, **Open Pull Request…** (pushes a `mergedesk/…` branch and opens
  the PR with `gh`, or GitHub's compare page). **Undo** puts the branch back exactly; **Abort** discards the worktree.
- **Detail** — the selected branch's predicted merges (with how each conflicting file would be resolved), commits not yet in the integration branch, files changed since it forked, and
  other active branches that changed the same files *since the two diverged* (measured from each pair's own merge
  base, so commits both already share don't count).

The Branches table's **Merge → develop** column shows each branch's predicted merge ("clean", "3 files (1 auto)",
"merged"); **Will conflict** filters to those that conflict. "auto" = a file rule in `.mergedesk.json` resolves it
(e.g. `pbxproj`, `regenerate`); the rest go to the history engine (MD-5) or a person.

**Daily run.** Settings ▸ Daily run schedules the digest (default 09:30) as a per-user LaunchAgent that runs
`MergeDesk --daily`: it fetches every added repository, predicts every merge, writes the digest and sends a macOS
notification only when something is new or needs you. A Mac asleep at that time runs it on wake. The menu-bar
icon shows the latest digests. From the command line: `mergedesk schedule --at 09:30` (runs `mergedesk daily --all`).
Digests are saved as Markdown in `~/Library/Application Support/MergeDesk/repos/<repo>/digests/`.

Comparisons use the **primary remote's copy** of each branch (what the team sees); local-only commits show as
"unpushed". Browsing never fetches; the daily run (and **Fetch & Run Now**) runs `git fetch --prune`, which only
updates remote-tracking refs.

**Merge safety.** Merges run in a worktree under `~/Library/Application Support/MergeDesk/…/worktrees/`, never in
your checkout. Apply refuses if the branch is checked out anywhere or moved since the merge started, and keeps the
old commit at `refs/mergedesk/backup/<UTC time>/<branch>`. Pushes are never forced. The repository's own commit
hooks run on merge commits. Every step is recorded in the audit log. If `gh` is installed and signed in, open PRs
and their CI state appear as badges on the Branches table. `MERGEDESK_SUPPORT_DIR=/some/folder` points the app and CLI
at another support folder (demos, testing).

| Command | What it does |
|---|---|
| `mergedesk list [--filter SCOPE] [--search TEXT] [--prefix P] [--json]` | Branches with ahead/behind, staleness and notes |
| `mergedesk show BRANCH [--max-commits N] [--max-files N] [--json]` | One branch: copies, comparisons, commits, files, overlaps |
| `mergedesk predict [--integration-only] [--json]` | Predicted conflicts vs integration branches and between active branches |
| `mergedesk daily [--all] [--no-fetch] [--no-notify]` | Fetch, predict, write today's digest, notify if something is new |
| `mergedesk digest` | Print the latest digest |
| `mergedesk schedule --at HH:MM \| --remove \| --run-now` | Install/remove the daily LaunchAgent, or run it now |
| `mergedesk merge BRANCH --into TARGET [--strategy merge\|squash] [--no-fetch]` | Start a merge session in its own worktree |
| `mergedesk session list \| show \| continue \| apply \| push \| pr \| undo \| abort ID` | Move a session along (`push`/`pr` ask first; `--yes` skips) |
| `mergedesk eval [--since 6.months] [--limit N] [--config FILE] [--json]` | Replay past merges and score automatic resolution against what was committed |
| `mergedesk version` | Merge Desk and git versions |
| `mergedesk doctor [--repo PATH]` | Checks git, the repository, its `.mergedesk.json` and that the integration branches exist |
| `mergedesk config validate [--repo PATH \| --file PATH]` | Validates a config; exits 1 on errors, prints warnings |
| `mergedesk config show [--repo PATH]` | The configuration in force (file merged with defaults) |
| `mergedesk config init [--repo PATH] [--force]` | Writes a `.mergedesk.json` with the defaults |
| `mergedesk fixtures list` | The conflict patterns and what each expects |
| `mergedesk fixtures build DIR [--pattern NAME]` | Builds the fixture repositories to inspect by hand |

## Layout

```
Sources/
  MergeDeskCore/        all logic, no UI
    Git/                GitClient (the only code that runs git), GitQuery (command + parser pairs), parsers, models
    Config/             RepoConfig (.mergedesk.json), ConfigLoader (decode + validate), GlobPattern
    Inventory/          InventoryBuilder, BranchRecord, BranchFilter, BranchDetailLoader, ComparisonCache
    Prediction/         Predictor (git merge-tree), PredictionStore (disk cache), prediction models
    Daily/              DailyRunner, DigestBuilder + DigestMarkdown, DailySchedule (LaunchAgent), notifiers
    Session/            MergeSession + state machine, SessionStore, SessionManager (worktree, apply, undo, push, PR)
    GitHub/             remote parsing, compare URLs, optional gh adapter (PRs, CI state)
    Resolve/            line merge + conflict blocks, ordered JSON, file resolvers, pbxproj validator, AutoResolver
    Eval/               ReplayBenchmark (mergedesk eval)
    Storage/            AuditLog (append-only JSONL), RepositoryRegistry, SupportPaths (~/Library/Application Support/MergeDesk)
  MergeDeskFixtures/    scripted, deterministic git repositories: conflict patterns + an origin/clone inventory fixture
  MergeDeskUI/          @Observable view models (AppModel, RepositoryModel) and SwiftUI views
  MergeDeskApp/         the app entry point only
  mergedesk/            CLI (swift-argument-parser)
Scripts/build-app.sh    packages MergeDeskApp as MergeDesk.app
Tests/MergeDeskCoreTests/  Tests/MergeDeskUITests/
docs/
  PLAN.md               product plan, decisions and phases
  mergedesk.schema.json JSON schema for editors
  examples/             example configs (Mercury iOS)
```

## Per-repository configuration

Commit a `.mergedesk.json` at the repository root (`mergedesk config init` writes one). Every key is optional;
see [docs/mergedesk.schema.json](docs/mergedesk.schema.json) and the
[Mercury iOS example](docs/examples/mercury-ios.mergedesk.json).

| Key | Default | Meaning |
|---|---|---|
| `integrationBranches` | `["develop", "main"]` | Branches everything is compared and predicted against |
| `primaryRemote` | `"origin"` | Remote whose tips are compared (the team's shared state) |
| `protectedBranches` | `["main", "develop", "release/*"]` | Only changed through a pull request |
| `staleDays` | `21` | Days without commits before a branch is stale |
| `driftBehindThreshold` | `50` | Commits behind the first integration branch before the digest says "drifting" |
| `activeBranchPrefixes` | `[]` (all) | Branches in the branch × branch conflict matrix |
| `fileClasses` | pbxproj → `pbxproj`, Package.resolved → `escalate` | First matching glob picks the Tier-1 strategy; a `regenerate` rule may carry its own `command` |
| `regenerateCommand` | none | Run after `regenerate` files are taken; required if any rule uses it |
| `verifyCommands` | `[]` | Run before a merge is marked ready |
| `autoApplyMinConfidence` | `{ "default": "high" }` | Below this, a person decides |

## Automatic resolution (Tier 1 + 2)

Right after `git merge` in a session's worktree, each conflicted file goes through:

| Tier | What | When it's applied |
|---|---|---|
| `pbxproj` | Three-way line merge keeping both sides' additions; refuses if a key would get two values (e.g. `CURRENT_PROJECT_VERSION`), then checks the result parses and every object reference resolves | high confidence for pure additions; edits are medium |
| `regenerate` | Keeps one side, then runs the class's `command` (or `regenerateCommand`) and commits its output | when the generator succeeds; otherwise the conflict is put back |
| `unionEntries` | Keeps both sides' new lines (changelogs written by hand) | high for pure additions |
| `jsonKeys` | Key-wise merge keeping key order and layout; same-key edits escalate | high |
| `escalate` | Always a person | — |
| rerere | git replays a resolution recorded earlier for the identical conflict (files with no rule) | high |

A resolution is applied only at or above `autoApplyMinConfidence` (default `high`); everything else stays
conflicted for a person, with the reason shown. The merge commit is still yours to apply, push or undo.

**Check rules against your own history before trusting them:** `mergedesk eval --config my.mergedesk.json`
replays past merges in a private clone (the repository, its hooks and rerere cache are untouched), applies the
rules and compares each automatic result with the file people actually committed. The gate: no wrong
resolution, ≥ 99 % exact or equivalent. On Mercury it caught that release notes are rewritten per release (union
was wrong 10/10, so they're `escalate` in the [Mercury config](docs/examples/mercury-ios.mergedesk.json)), and
showed pbxproj resolution 9/9 correct with 3 more below-threshold proposals that would also have been exact.
Note: `--since` uses git's dates; values beyond ~50 years wrap to before 1970 and match nothing.

## Safety principles

Merge Desk never works in your checkout (merges run in their own worktree), saves a backup ref before every merge,
never pushes or deletes without an explicit confirm, sends protected branches through a PR, and sends nothing off
the machine except `git fetch/push` and the optional `gh` CLI.

## Fixture repositories

Every resolver behaviour starts as a fixture in `Sources/MergeDeskFixtures/FixturePattern.swift`: a tiny repository
built with real git, isolated from your git config, with fixed dates, so commit ids are identical on every machine.
The tests check that git reports exactly the conflicts each fixture declares; later phases check each resolver's
output against the fixture's expected resolution.
