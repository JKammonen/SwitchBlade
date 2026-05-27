# SwitchBlade Agent Context

This file is **repo-specific delta only**. Shared workflow, `Rules of Engagement`,
`Baba Yaga`, handoff rules, brevity, and verification boundaries live in:

- `/Users/jannekammonen/JK/jkammone/Claude/AGENTS.md`
- `/Users/jannekammonen/JK/jkammone/Claude/CLAUDE.md`

## Read First

- `CLAUDE.md` in this repo
- `~/.claude/projects/-Users-jannekammonen-JK-jkammone-Claude/memory/project_switchblade.md`
- `~/.claude/projects/-Users-jannekammonen-JK-jkammone-Claude/memory/positive_switchblade_codesign_keychain.md` before touching signing, keychains, or TCC-sensitive build flow
- `/Users/jannekammonen/.claude/skills/dev/SKILL.md` for general workflow and git hygiene

## Critical Repo Rules

- Build scripts must never leave the global user keychain search list modified.
- Window titles and preview contents are sensitive. Default diagnostics log ids/counts/timing, not titles or image content.
- If the same live symptom survives two plausible fixes and green tests, stop adding heuristics and gather diagnostics from the real app path.

## Critical Settled Decisions

1. No `SCStream`. Stay with per-call `SCScreenshotManager.captureImage`.
2. Soft timeout, not hard timeout. Do not rename or overclaim the behavior.
3. No `sharingState=0` windows except Microsoft Teams.
4. Local signing cert, not ad-hoc signing.
5. Custom test runner, not XCTest / swift-testing. Run `swift run SwitchBladeTests`.
6. Wake / screen-params path needs both invalidation and warmup; sleep invalidates only.
7. Selected-window activation is AX-targeted before app activation.

## Slice Routing

Identify the slice before editing:

1. store / state: `SwitcherStore`, `MRUTracker`, `HotkeyMonitor`
2. capture / catalog: `WindowCatalog`, `SCContentCache`, `PreviewCacheStore`
3. panel / UI: `SwitcherPanelController`, `SwitcherLayoutCalculator`, `SwitcherView`
4. permissions / signing: `PermissionService`, `scripts/`
5. tests / custom runner: `Sources/SwitchBladeTests/`

Routing:

- unclear ownership -> `codebase-scout`
- stubborn ScreenCaptureKit / AX / TCC bug after 2 failed fixes -> `regression-hunter`

## Build & Verify

```bash
bash scripts/build-app.sh
swift run SwitchBladeTests
log stream --predicate 'subsystem == "com.jannekammonen.SwitchBlade"'
```

- `swift build` is not enough for user-tested behavior. Rebuild the signed app bundle with `bash scripts/build-app.sh`.
- If the user will test the app, quit any old process and relaunch the rebuilt `dist/SwitchBlade.app`.

## Repo-Specific Conventions

- Finnish UI text, English code/comments/commit messages.
- All user-facing strings go through `L10n.tr(.key)`.
- MRU is per-window first. Do not collapse same-app windows into one rank.

## Privacy Boundary

Do not read personal, health, therapy, nutrition, or unrelated project memories for
SwitchBlade work unless Janne explicitly asks.
