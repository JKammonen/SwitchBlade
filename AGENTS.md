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

- `feedback_direct_communication.md` — lead with the gap, not the win. Numbers > adjectives.
  Say what a test proves AND what it doesn't.
- `feedback_verification_discipline.md` §3 — green build is not a green test. Verify the
  thing the user reported.
- `feedback_root_cause_not_speculation.md` — two failed code changes without improvement
  on the real symptom = stop and reconsider the bug model.

## Workflow Triggers & Baba Yaga Categories

Before the first Edit/Write of a task, the assistant declares exactly one of:

- `Baba Yaga: <category>` — naming one of the five categories below verbatim.
- `Rules of Engagement` — workflow applies.

Include a short human-readable reason in the same chat message so the marker is
understandable to Janne, e.g. `Rules of Engagement: this touches SwitchBlade code, so I
will check status and route the slice before editing.`

Fuzzy match → default `Rules of Engagement`. Do not ask the user; the user overrides silently by saying "skip the workflow" or continuing past an `Baba Yaga:` line without comment.

Baba Yaga categories (must match exactly):

- Typo or copy edit
- Single read-only command, lookup, or grep
- One-line fix to an already-known file, with no API, data model, behavioral contract, or test expectation change
- Pure documentation edit with no code-behavior impact
- User explicitly asks for analysis only, not implementation

Handoff/resume triggers (`lue handoff`, `jatka handoffista`, `continue from handoff`, `Claude jäi tähän`, `tee seuraava askel tästä`) run the 5-step resume path before any Edit/Write:

1. Read the handoff.
2. `git status --short --branch` + `git log -1`.
3. Validate at least one technical claim from the handoff against current code or data.
4. Decide full workflow or documented lightweight resume.
5. Record the decision in the plan Context.

Words like "non-trivial", "complex", "multi-file", or "worth using scout" are NOT trigger boundaries — only the categories above.

## Pre-Edit Guard

When `Rules of Engagement` and the task touches `SwitchBlade/**`, run this 4-step thought before the FIRST Edit/Write:

1. `Rules of Engagement`? (If `Baba Yaga:` was declared and accepted, proceed without slice routing.)
2. Which slice — store/state (`SwitcherStore`, `MRUTracker`, `HotkeyMonitor`), capture/catalog (`WindowCatalog`, `SCContentCache`, `PreviewCacheStore`), panel/UI (`SwitcherPanelController`, `SwitcherLayoutCalculator`, `SwitcherView`), permissions/signing (`PermissionService`, `scripts/`), or test runner (`Sources/SwitchBladeTests/`)?
3. Routing: no named switchblade-builder yet. Use `codebase-scout` to confirm module ownership when unclear. Re-read `Critical Settled Decisions` BEFORE editing capture or ScreenCaptureKit paths — no SCStream, no hard timeout, no `sharingState=0` exceptions beyond Teams. For stubborn ScreenCaptureKit / AX / TCC bugs after 2 failed fixes use `regression-hunter` (Opus).
4. Do not start implementation in the main session until the slice + settled-decision check are recorded.

Goal: stop the "teen itse nopeasti" reflex and avoid re-litigating settled SCK/AX decisions. Orient → re-read settled decisions → plan → decide → then edit.

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
6. **Lifecycle observers: invalidate + warm pair on wake / screen-params; sleep
   invalidates only.** Cold SCKit pipelines after idle return `.timedOut` more
   often than `.failed`, so both `WindowCatalog.capturePreviews` capture retry
   and `handleCaptureContentInvalidation` warmup must cover the timeout path.
   `willSleep` deliberately skips warm — no future Cmd+Tab to preempt. Removing
   either half (the timeout-retry or the wake-warm) reintroduces the post-idle
   empty-tile regression that took ~12 commits to land.
7. **Selected-window activation is AX-targeted before app activation.** AX
   raise/focus alone does not bring many apps frontmost. Do not activate the app
   before targeting the selected AX window; AppKit can otherwise raise the
   app's previously-main sibling window. The intended sequence is AX
   raise/main/focus first, then `NSRunningApplication.activate(options: [])`.

## Build & Run

```
bash scripts/build-app.sh        # builds, signs with local cert, emits dist/SwitchBlade.app
swift run SwitchBladeTests       # runs all tests, exit non-zero on failure
```

For any user-tested behavior change, `swift build` is not enough. Build the signed
app with `bash scripts/build-app.sh`, quit any old running SwitchBlade process, and
launch the rebuilt `dist/SwitchBlade.app` before saying the live app is updated.

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
- MRU is per-window first: preserve independent ranks for same-app windows. Fallbacks
  may recover recreated windows by app/title signature, and by app identity only when
  that app has exactly one visible window.
- Verification scales with risk: docs-only -> `git diff --check`; focused code ->
  `swift build` + `swift run SwitchBladeTests`; UI/lifecycle changes also need manual
  app verification when possible. If the user will test the app, rebuild/sign
  `dist/SwitchBlade.app` and restart the running app; `.build/debug/SwitchBlade`
  does not update the launched app bundle.
- Stage exact files only, never `git add .`.

## Parallel Agent / Scout Routing

Use parallel agents, scouts, or reviewer roles when the task has separable
uncertainty, not by default. Good triggers:

- the bug crosses 2+ modules, e.g. store/order + catalog + activation
- the same user-visible symptom survives 2 plausible fixes
- commit history or prior decisions matter to the next change
- implementation and test design can proceed in parallel
- a review pass is likely to catch a regression before commit

Prefer bounded roles:

- scout: confirm ownership, patterns, and relevant tests
- regression hunter: inspect history and prior decisions
- test reviewer: check what tests prove and what they do not
- docs/context updater: update `AGENTS.md` / `CLAUDE.md` after behavior settles

Do not use parallel agents for typo/docs-only/simple one-file changes, tightly
coupled edits where agents would touch the same files, or live GUI verification
that requires one operator interpreting the desktop.

## Persistent Live-Symptom Rule

If the same reported behavior survives two plausible fixes and green tests, stop
adding heuristics. Before the next behavioral fix:

1. Write the current bug model in one sentence.
2. Add privacy-safe diagnostics or a targeted reproduction hook.
3. Build/sign the app and reproduce the real symptom once when possible.
4. Use observed diagnostic output to choose the next fix.
5. Add a regression test for the proven branch.
6. State what the test proves and what remains live-integration-only.

For MRU/order bugs, diagnostics should log only IDs, pid, app identity, signature
match/fallback path, frontmost marker, and final rank by default. Do not log
window titles unless Janne explicitly asks for a one-off diagnostic build.

## Capability Escalation

Use the strongest available reasoning/model mode for cross-module bugs, repeated
failed fixes, architecture decisions, or high-risk refactors. Use normal/default
mode for narrow implementation once the bug model is clear.

Escalate from direct editing to scout/review/diagnostics when uncertainty is
about the system, not syntax. Do not substitute a larger model for live
verification when the failure depends on macOS AX, CGWindowList, TCC, signing, or
real app behavior.
