# Merge Desk — branch dashboard, merge planner and history-aware conflict resolver

**Status:** Plan v2 · MD-0 implemented 2026-10-24 (not committed) · **Date:** 2026-10-24 · **Owner:** Sandeep GS
**Form:** standalone **native macOS app** + `mergedesk` CLI, in its **own repository**, usable on any Cricbuzz git repo.
Mercury-iOSApp is the first adopter and the accuracy benchmark.

---

## 0. Decisions (2026-10-24)

| # | Question | Decision |
|---|---|---|
| 1 | Home | **Standalone app** (not a tab in `./mercury ui`) |
| 2 | Predict conflicts against | **`develop`** and **`main`**, plus **every active feature branch against every other** (overlap matrix) |
| 3 | Stale threshold | **21 days** without commits (configurable per repo) |
| 4 | GitHub data | **Optional `gh` adapter.** If `gh` is installed and signed in, show PR + CI columns and offer "Open PR"; if not, those columns are hidden and everything else works. Recommended: `brew install gh && gh auth login` once per machine. No tokens stored by Merge Desk itself. |
| 5 | AI assist | **Not included.** Resolution is deterministic + history-based; nothing leaves the machine. |
| 6 | Scope | **Reusable across Cricbuzz repos.** Nothing Mercury-specific in the code; repo specifics live in a per-repo `.mergedesk.json`. |

## 1. Problem

Measured on Mercury-iOSApp: **32 local / 45 remote branches** (18 with commits in the last 21 days), **~250 merge
commits in 6 months**, and the same files conflict again and again:

| File (or class) | Merges that touched it |
|---|---|
| `Source/CricbuzzMobile.xcodeproj/project.pbxproj` | 72 |
| `Source/release-notes/CricbuzzMobileRelease.md` | 49 |
| `Source/Documentation/catalogs/*.md` | 38–45 each |
| `*.generated.swift` corpora | 33–42 each |
| `Source/Documentation/features/*.md`, `mercury-open-aliases.json` | 33–39 |

Most are mechanical and have one right answer; the few real conflicts get no help beyond `<<<<<<<`. And there is no
single view of which branches are stale, already merged, or about to collide — with `develop`, `main`, or each other.

## 2. Goals and non-goals

**Goals**
1. One window listing every branch of any repo with health: ahead/behind `develop` and `main`, last commit, author,
   merged/stale, **predicted conflicts** (vs `develop`, vs `main`, vs other active branches).
2. Merge any branch into any other safely: isolated worktree, backup ref, one-click undo.
3. Resolve conflicts **accurately** using file-type rules and **git history**, each decision with evidence and a
   confidence score; anything uncertain goes to a person.
4. Run **daily** on its own (fetch, recompute, morning digest + notification).
5. Prove accuracy by **replaying a repo's own historical merges**.

**Non-goals**
- Replacing GitHub PR review or CI.
- Auto-resolving real semantic conflicts. No AI, no code sent anywhere.
- Pushing, force-pushing or deleting remote branches without an explicit confirm.

## 3. Product shape

```
merge-desk/                        (new repo, e.g. cricbuzz/merge-desk)
├── Package.swift
├── Sources/
│   ├── MergeDeskCore/             all logic; no UI; fully unit-tested
│   ├── mergedesk/                 CLI (swift-argument-parser) — scripts, CI, launchd jobs
│   └── MergeDeskApp/              SwiftUI macOS app (macOS 14+), thin over Core
├── Tests/MergeDeskCoreTests/      fixture-repo golden tests, parsers, resolvers
├── Fixtures/                      scripts that build tiny git repos per conflict pattern
└── docs/
```

**Why native Swift:** the team writes Swift daily, so it is easy to own; `Process` + system git is all it needs;
a real macOS app gives a menu-bar extra, notifications and a login item for the daily run with no server, no ports,
no browser security surface. The CLI shares the same Core, so everything the app does is scriptable and testable.

**Distribution:** Developer ID–signed, notarized `.dmg` from GitHub Releases of the merge-desk repo; CLI via an
internal Homebrew tap (`brew install cricbuzz/tap/mergedesk`). Updates: the app checks the repo's latest release
(no third-party updater dependency in v1).

## 4. Architecture (MergeDeskCore)

```
┌────────────── MergeDeskApp (SwiftUI) ───────────────┐   ┌──── mergedesk CLI ────┐
│ Repos sidebar │ Branches │ Matrix │ Merge │ Workbench │   │ list predict merge    │
│ Digest │ Audit │ Settings │ Menu-bar extra           │   │ resolve verify daily  │
└──────────────────────────┬───────────────────────────┘   │ eval schedule undo    │
                           │                                └──────────┬────────────┘
┌──────────────────────────▼───────────── MergeDeskCore ───────────────▼────────────┐
│ RepoRegistry     repos the user added, each with its RepoConfig                    │
│ RepoConfig       decodes .mergedesk.json (+ built-in defaults)                     │
│ GitClient        the ONLY code that runs git: argv arrays, -z / porcelain v2 parse │
│ Inventory        branches, ahead/behind, merged, stale, owners                     │
│ Predictor        merge-tree dry runs → conflict matrix, cached by (sha, sha)       │
│ MergeSession     worktree, backup ref, state machine, undo                         │
│ Resolvers/       Tier 1 file-class · Tier 2 rerere · Tier 3 history engine         │
│ Verifier         markers, per-type parse/lint, repo-defined verify commands        │
│ Digest           daily report (Markdown + in-app)                                  │
│ AuditLog         append-only JSONL per repo                                         │
│ GitHubAdapter    optional, via `gh` CLI; absent = feature hidden                    │
└────────────────────────────────────────────────────────────────────────────────────┘
```

**Design rules**
- `GitClient` is a protocol; the real one wraps `/usr/bin/git` (or configured path) with `Process`, argv only,
  never a shell string. Tests use fixture repos (real git) and a fake for edge parsing.
- Swift Concurrency throughout; every git call is async and cancellable; UI updates on the main actor only.
- **Never touch the developer's checkout.** Merges run in `~/Library/Application Support/MergeDesk/worktrees/<repo-id>/<session-id>`.
- **Every write is reversible:** before a merge, target tip → `refs/mergedesk/backup/<UTC-ts>/<branch>`.
- No magic strings: ref namespaces, thresholds, globs and commands come from `RepoConfig` defaults or `.mergedesk.json`.

## 5. Per-repo configuration — `.mergedesk.json` (committed in each adopting repo)

Everything repo-specific lives here; the app works with defaults if the file is absent.

```json
{
  "schemaVersion": 1,
  "integrationBranches": ["develop", "main"],
  "protectedBranches": ["main", "develop", "release/*"],
  "staleDays": 21,
  "activeBranchPrefixes": ["feature/", "bugfix/", "hotfix/"],
  "fileClasses": [
    { "glob": "**/*.generated.swift", "strategy": "regenerate" },
    { "glob": "Source/Documentation/catalogs/*.md", "strategy": "regenerate" },
    { "glob": "**/*.pbxproj", "strategy": "pbxproj" },
    { "glob": "Source/release-notes/*.md", "strategy": "unionEntries" },
    { "glob": "**/*.json", "strategy": "jsonKeys" },
    { "glob": "**/Package.resolved", "strategy": "escalate" }
  ],
  "regenerateCommand": ["python3", "./mercury", "fix"],
  "verifyCommands": [
    ["python3", "./mercury", "fix", "--check"]
  ],
  "autoApplyMinConfidence": { "default": "high" }
}
```

Mercury's existing `.gitattributes` merge driver and post-merge hook keep working for people merging by hand; Merge
Desk does the same thing explicitly via `regenerate`. A Kotlin/Android or web repo just ships different file classes
and commands.

## 6. Features

### 6.1 Repos and branch inventory (read-only)
- Add any local clone (folder picker); sidebar of repos; per-repo refresh.
- Columns: name · local/remote/both · last author · age · ahead/behind **`develop`** · ahead/behind **`main`** ·
  merged into develop/main · stale (> 21 d) · PR + CI (if `gh`) · predicted conflicts · risk score.
- Filters: mine, active, stale, merged-not-deleted, will-conflict, author, prefix.
- Branch detail: unique commits, files touched, which other active branches touch the same files.
- Bulk tidy (confirmed): delete local branches already merged into `develop`; list remote ones to delete via PR/GitHub.

### 6.2 Conflict prediction — three views
`git merge-tree --write-tree --name-only -z <target> <source>` gives the merge result with no worktree. Measured on
this repo: ~25 ms per pair. With 18 active branches that is 18×2 integration pairs + 153 branch pairs ≈ 190 runs
≈ 5 s cold, near-instant warm (cache keyed by `(target_sha, source_sha)`).
1. **vs `develop`** — will this branch merge cleanly into develop today?
2. **vs `main`** — same for main / release.
3. **Branch × branch matrix** — heat map of active feature branches that conflict with each other, with the file
   list per cell, so two people learn early they are editing the same thing.
Each conflicted file is tagged with the tier that would resolve it: *"4 conflicts — all auto-resolvable"* vs
*"1 needs a human"*.

### 6.3 Merge sessions
Pick **source → target**, strategy (merge commit / squash / rebase-onto for unpushed local branches).
```
PLANNED → PREFLIGHT → MERGING → RESOLVING → VERIFYING → READY → APPLIED → (PUSHED | PR_OPENED)
                    ↘ ABORTED (anywhere)                            ↘ UNDONE
```
- Preflight: fetch; record both shas; target not protected (else PR route); write backup ref.
- APPLIED moves the local target ref only. Push is a separate confirmed action. Protected branches
  (`main`, `develop`, `release/*`) → push the merge to a new branch and open a PR (via `gh`, or show the compare URL).
- Session state persisted (`Application Support/MergeDesk/sessions/`) so an app quit never loses work.

### 6.4 Resolution engine

Each conflicted file runs through the tiers; a resolution is auto-applied only if its confidence meets the file
class's threshold. Otherwise it goes to the Workbench with everything learned.

**Tier 1 — file-class strategies (deterministic)**

| Strategy | Behaviour |
|---|---|
| `regenerate` | Take either side, run `regenerateCommand` once after all files are resolved, include the output |
| `pbxproj` | Structural 3-way merge of the object graph by UUID: add/add → union; delete vs untouched → delete; edit/edit same key → escalate. Re-emit in Xcode's canonical layout; validate with `plutil -lint` and by re-parsing |
| `unionEntries` | Both sides' new entries, ordered by commit date, de-duplicated |
| `jsonKeys` | Key-wise 3-way merge; same-key edits escalate |
| `escalate` | Always to a person (e.g. `Package.resolved`) |
| *(none matched)* | Falls through to Tier 2/3 |

**Tier 2 — rerere.** Enabled inside Merge Desk worktrees with a per-repo cache, so a resolution made once replays.

**Tier 3 — history engine (resolution from git commits).** For each conflicting hunk:
1. Commits that produced each side since the merge base: `git log <base>..<side> -L<start>,<end>:<file>` + `git blame`.
2. Evidence attached: sha, Conventional Commit type/scope/subject, author, date, PR number from subject.
3. Classification:

| Pattern | Resolution | Confidence |
|---|---|---|
| Same text on both sides, or same `git patch-id` | Take once | High |
| One side's change already present on the other (cherry-pick, `git cherry`) | Side with the change + later edits | High |
| One side's commit reverts a commit the other side contains | Honour the revert | High |
| One side whitespace/format only | Content side, re-format | Medium |
| Both sides only **added** lines (imports, enum/switch cases, list entries) | Union (imports sorted, else by commit date) | Medium |
| `fix:` lines on one side, `refactor:` moved them on the other | Escalate, highlight the fix to re-apply | Human |
| Both edited the same logic | Escalate with both commit stories side by side | Human |

### 6.5 Workbench
Base · ours · theirs · result per hunk, with the deciding tier, confidence and commit evidence ("line 42 changed in
`a1b2c3d fix(match-center): …` by X on 2026-10-20"). Actions: accept / ours / theirs / edit / mark resolved; open in
Xcode or the user's editor. A file is resolved only when no conflict markers remain.

### 6.6 Verification gate (before READY)
1. No `<<<<<<<` / `=======` / `>>>>>>>` anywhere.
2. Per type: `swiftc -parse` (`.swift`), `plutil -lint` (plists, pbxproj), JSON parse, YAML parse.
3. Repo `verifyCommands` (Mercury: `./mercury fix --check`; can add a test or build command).
   Builds use the developer's shared DerivedData — Merge Desk never passes `-derivedDataPath`.
4. Generated merge commit message in Conventional Commits form, listing auto-resolved files and tiers; no AI/tool trailers.

### 6.7 Daily operation
- Login-item helper (SMAppService) runs **daily at a chosen time** (default 09:30) per registered repo:
  `fetch --prune` → inventory → three prediction views → digest. Read-only: never merges or pushes.
- Same thing headless: `mergedesk daily --repo <path>`; `mergedesk schedule --at 09:30` installs a launchd agent
  for people who prefer the CLI.
- **Digest** (in-app + `~/Library/Application Support/MergeDesk/digests/<repo>/YYYY-MM-DD.md`): new conflicts since
  yesterday (vs develop, vs main, between branches), branches drifting behind develop, stale (> 21 d) and
  merged-not-deleted branches, "rebase these today". macOS notification only when something **new** appears.
- Menu-bar extra: red dot when any of *your* branches newly conflicts with `develop`.

### 6.8 Audit and undo
Per-repo append-only `audit.jsonl`: action, user, time, branch, sha before/after, backup ref, per-file tier and
confidence. Undo restores the backup ref (refused if the branch moved since, unless confirmed). Backup refs older
than 30 days are pruned by the daily run.

## 7. Accuracy — measured, not claimed

`mergedesk eval --repo <path> --since 6.months`:
1. Every 2-parent merge commit in range (~250 on Mercury).
2. Re-run the merge of its parents in a scratch worktree with the engine.
3. Compare each engine-resolved file with the real merge commit.
4. Report per tier / file class: auto-resolved %, exact-match %, escalated %, **wrong %**.

Ship gates (per repo, before auto-apply is turned on for it):
- Tier 1 and Tier 3 "High": **≥ 99% exact match**, **0 wrong** on `regenerate` / `pbxproj` classes.
- Overall wrong rate **< 0.5%**; a class above that gets its threshold raised to "escalate" automatically.
- Fixture-repo suite runs in the merge-desk repo's CI on every PR.

## 8. Safety rules

- Never runs in, stashes, resets or checks out the developer's working tree.
- Never pushes, force-pushes, deletes remote branches or opens a PR without an explicit confirm.
- Protected branches only through a PR.
- Never auto-applies below threshold.
- No network calls except `git fetch/push` and the optional `gh`. No telemetry, no AI.
- App sandbox off (it must run git on arbitrary folders); hardened runtime on; repos added only by the user's folder pick.

## 9. Testing

- **Fixture repos** built by script for each pattern in 6.4 (add/add, cherry-pick, revert, move + fix, pbxproj
  add/add and edit/edit, JSON same-key, generated files) with golden expected trees.
- XCTest for `GitClient` parsing (porcelain v2, `-z`, odd branch names with spaces/unicode), pbxproj merge
  round-trip on real project files, JSON merge, classifier, session state machine, undo.
- UI: view models tested as plain Swift; a small XCUITest smoke flow (add repo → list → predict).
- Replay benchmark (section 7) against Mercury as the end-to-end accuracy test.

## 10. Delivery phases

Each phase is usable on its own, tested, and committed separately.

| Phase | Scope | Done when |
|---|---|---|
| **MD-0 Foundations** ✅ | New `merge-desk` repo, SPM layout, `GitClient`, `RepoConfig` + `.mergedesk.json` schema, fixture generator, AuditLog, CI | Fixture repos build; parser tests pass; CI green (CI runs once the GitHub remote exists) |
| **MD-1 Inventory** | CLI `list/show`; app shell with repos sidebar + Branches table + filters + detail | On Mercury, all 77 refs match `git` for ahead/behind develop & main, merged, stale |
| **MD-2 Prediction + daily** | Predictor with cache, 3 views (vs develop, vs main, branch matrix), digest, login-item / launchd schedule, notifications, menu-bar extra | 20 sampled pairs match real `git merge` outcomes; digest appears at the set time |
| **MD-3 Merge sessions** | Worktree sessions, state machine, backup refs, undo, confirmed push, PR route (`gh` or compare URL), `gh` adapter columns | Merge → undo restores exact sha; protected branch refuses direct push |
| **MD-4 Tier 1 + 2** | regenerate, pbxproj, unionEntries, jsonKeys, escalate, rerere | Replay on Mercury: ≥ 99% exact, 0 wrong on these classes |
| **MD-5 Tier 3 history engine** | `-L`/blame evidence, patch-id / cherry / revert detection, add-only union, classifier, confidence | Replay: "High" ≥ 99% exact; evidence shown per hunk |
| **MD-6 Workbench + verification** | 3-pane workbench, editor hand-off, verification gate, commit message generation | A real multi-file conflict resolved end-to-end and passes the gate |
| **MD-7 Second repo + release** | Onboard one more Cricbuzz repo (e.g. Android) with its own `.mergedesk.json`; signed/notarized DMG; Homebrew tap; docs | Second repo's replay benchmark meets gates; installable by a teammate from the DMG |
| **MD-8 Mercury adoption** | Add `.mergedesk.json` to Mercury-iOSApp; mention in AGENT-TOOLING / Mercury CLI reference | Mercury digest runs daily for the team |

Fastest value: MD-0 → MD-2 delivers the read-only dashboard, conflict matrix and daily digest with zero risk to any
branch. MD-3 → MD-4 then removes most of the repeated conflict pain.

## 11. Remaining open points (small)

1. **Repo name / location** for the app (proposal: `cricbuzz/merge-desk`) — needs someone with org rights to create it.
2. **Signing:** which Developer ID team signs the internal DMG.
3. **Minimum macOS:** proposal macOS 14 (Sonoma) for SwiftUI `Table`, `MenuBarExtra`, `SMAppService`.
