# SwitchBlade Agent Context

This file is the shared coordination map for AI agents working on SwitchBlade with Janne.
Repo-root `AGENTS.md` and `CLAUDE.md` are the cross-agent source of truth. External
memory and skills are supplemental handover context; read only the ones relevant to
the current task and verify live repo state before acting.

## Shared Context Policy

- Keep cross-agent canonical repo context in `AGENTS.md` and `CLAUDE.md`.
- Treat agent-local memories and tool-specific caches as supplemental/historical only.
- When shared workflow, architecture, or critical-decision facts change, update these
  repo files in the same change so Claude Code, Codex, and Copilot can all follow the
  same source.

## Shared Skill Sources

These Claude skills are reference material when the task matches their scope. Codex /
Copilot cannot auto-load them but they can be opened explicitly by path.

- `/Users/jannekammonen/.claude/skills/dev-workflow/SKILL.md`
  - General repo work, git hygiene, commit/PR habits.

## Shared Memory Sources

Memory directory (Claude Code auto-loads, other agents do NOT):

`/Users/jannekammonen/.claude/projects/-Users-jannekammonen-JK-jkammone-Claude/memory/`

Memory files may contain historical commit refs or "current status" snapshots — treat
those as handover context only. Always verify live state with `git status`, `git log`,
and `swift run SwitchBladeTests` before acting.

SwitchBlade core context:

- `project_switchblade.md` — current architecture, module layout, critical settled
  decisions, known gaps, build/run commands. Lean (~120 lines).

Always-active rules that apply here too:

- `feedback_direct_style.md` — lead with the gap, not the win. Numbers > adjectives.
  Say what a test proves AND what it doesn't.
- `feedback_verify_before_done.md` — green build is not a green test. Verify the
  thing the user reported.
- `feedback_root_cause_not_speculation.md` — two failed code changes without improvement
  on the real symptom = stop and reconsider the bug model.

## When To Read What

- General SwitchBlade feature or bugfix:
  - Read this file and `CLAUDE.md` first, then inspect the live files touched by the task.
- Window enumeration, previews, stale cache, ScreenCaptureKit behavior:
  - Read `Sources/SwitchBladeCore/WindowCatalog.swift`, `PreviewCacheStore.swift`, and the settled decisions below.
- Ordering, hotkeys, selection, close/quit/hide, store state:
  - Read `Sources/SwitchBladeCore/SwitcherStore.swift`, `MRUTracker.swift`, `HotkeyMonitor.swift`, and relevant `SwitcherStoreTests`.
- Panel sizing, layout, click-outside behavior, SwiftUI tiles:
  - Read `SwitcherPanelController.swift`, `SwitcherLayoutCalculator.swift`, `SwitcherView.swift`, and layout tests.
- Permissions, signing, TCC behavior:
  - Read `PermissionService.swift`, `AppDelegate.swift`, `scripts/build-app.sh`, and `scripts/setup-local-codesign.sh`.
- Regression bisect or "why was X done this way":
  - Read `project_switchblade.md` first. Expand to commit history only after checking live repo state.

## Privacy Boundary

- Do not read personal, health, therapy, nutrition, or unrelated project memories when
  working on SwitchBlade unless Janne explicitly asks.
- Window titles and preview contents can be sensitive. Keep logs and tests focused on
  IDs/counts/timing unless a user-visible title is required for the task.
- Do not persist preview images or window contents beyond the current process without
  an explicit privacy design and user approval.

## Critical Settled Decisions (do not re-litigate without an explicit ask)

1. **No SCStream.** User rejected continuous capture pipeline due to resource cost.
   Stay with per-call `SCScreenshotManager.captureImage`. Revisit only if measured
   p95/p99 metrics prove the per-call cold-start is unsolvable.
2. **Soft timeout, not hard.** `captureWithSoftTimeout` uses a detached task + one-shot
   continuation. Cancellation is requested but ScreenCaptureKit may ignore it.
   Comments and naming are deliberately honest about this. Do not rename it to
   `captureWithTimeout` or claim it's a hard timeout.
3. **No `sharingState=0` windows except Microsoft Teams.** ChatGPT desktop, autofill
   prompts, DRM surfaces, etc. set `kCGWindowSharingNone` and stay filtered out.
   Microsoft Teams is the exception because real meeting/chat windows can use this
   state; those tiles may fall back to the app-icon treatment instead of a preview.
4. **Local signing cert, not ad-hoc.** `scripts/setup-local-codesign.sh` creates a
   stable self-signed identity. Ad-hoc signing would lose TCC permissions on every
   rebuild, breaking incremental dev.
5. **Custom test runner, not XCTest / swift-testing.** Xcode is not installed on
   Janne's machine; CLT-only toolchain. `Sources/SwitchBladeTests/main.swift` is
   the runner. Run with `swift run SwitchBladeTests`.

## Build & Run

```
bash scripts/build-app.sh        # builds, signs with local cert, emits dist/SwitchBlade.app
swift run SwitchBladeTests       # runs all tests, exit non-zero on failure
```

To stream the app's structured logs:

```
log stream --predicate 'subsystem == "com.jannekammonen.SwitchBlade"'
```

## Conventions

- Finnish UI text, English code + comments + commit messages.
- All public-facing strings go through `L10n.tr(.key)` so the language picker (System /
  English / Suomi) works. Both `englishTable` and `finnishTable` need a value for every
  `L10n.Key` case.
- Direct-style communication in chat replies AND commit messages: lead with the gap,
  drop framing verbs ("production-grade", "world-class", "robust"), name what the test
  proves AND what it doesn't.
- CI runs on macos-15 (`.github/workflows/tests.yml`). Keep tests deterministic;
  per-test isolated UserDefaults via `makeIsolatedUserDefaults()`.

## Low-Context Workflow

- Start narrow: inspect `git status --short --branch`, the latest diff, and only the
  files relevant to the task.
- Expand context when behavior crosses module boundaries (store/catalog/view/tests) or
  when two attempted fixes fail to improve the measured symptom.
- On "continue", anchor to the latest commit/diff before loading external memory.
- Treat hard-coded counts in memory as last-known snapshots. Verify current counts with
  `swift run SwitchBladeTests`.

## Collaboration Workflow

- Before editing: check `git status --short --branch`; if files are dirty, work with
  those changes and do not revert user/agent edits.
- Prefer existing SwitchBlade patterns: protocol-backed dependencies, `@MainActor`
  store/view state, actor/LockedValue bridges for nonisolated hot paths, and focused
  custom-runner tests.
- Verification scales with risk: docs-only -> `git diff --check`; focused code ->
  `swift build` + `swift run SwitchBladeTests`; UI/lifecycle changes also need manual
  app verification when possible.
- Stage exact files only, never `git add .`.
