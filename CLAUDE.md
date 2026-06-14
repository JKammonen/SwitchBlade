# SwitchBlade — macOS Cmd+Tab Replacement

## Quick Start

```bash
cd /Users/jannekammonen/JK/jkammone/Claude/Repositories/SwitchBlade
bash scripts/build-app.sh             # builds, signs with local cert, emits dist/SwitchBlade.app
swift run SwitchBladeTests            # runs the in-process test suite, exit non-zero on failure
```

For user-tested behavior changes, `swift build` is not enough. Rebuild/sign with
`bash scripts/build-app.sh`, quit any old running SwitchBlade process, and launch the
rebuilt `dist/SwitchBlade.app`; `.build/debug/SwitchBlade` does not update the app
bundle the user is running.

Streaming logs:

```bash
log stream --predicate 'subsystem == "com.jannekammonen.SwitchBlade"'
```

## Architecture

```
HotkeyMonitor (CGEventTap + NSEvent)
        │
        ▼
SwitcherStore  ──►  WindowCatalog  ──►  SCContentCache (actor)
   │   │   │              │                     │
   │   │   │              ▼                     ▼
   │   │   │      CGWindowList +         SCShareableContent
   │   │   │      AX (minimized)         SCScreenshotManager
   │   │   │
   │   │   ▼
   │   PreviewCacheStore  (windowID + signature LRU)
   │   │
   │   ▼
   MRUTracker  (rank entries: windowID + signature + app identity)
   │
   ▼
SwitcherPanelController  ──►  NSPanel + NSHostingView (SwiftUI SwitcherView)
```

### Target layout

| Target | Purpose |
|--------|---------|
| `Sources/SwitchBlade/` | Thin executable. `AppMain.swift` only — constructs `AppDelegate`. |
| `Sources/SwitchBladeCore/` | All production logic. Library target imported by exec + tests. |
| `Sources/SwitchBladeTests/` | Custom in-process runner. Run with `swift run SwitchBladeTests`. |

### Module roles

| Module | Role |
|--------|------|
| `SwitcherStore` | `@MainActor ObservableObject`. Holds `items`, `selectedID`, `isVisible`. Orchestrates open/commit, including the prepared-hidden grace window for quick Cmd+Tab release. |
| `WindowCatalog` | `Sendable`. Window enumeration + ScreenCaptureKit capture. Owns `SCContentCache` actor. |
| `SCContentCache` | Actor. Caches `SCShareableContent` with staleness tracking (5 s threshold). |
| `WindowActivator` | `Sendable`. Activate / close / quit / hide. Selected-window activate/snap target the AX window first, then activate the app so the target can become frontmost. |
| `PermissionService` | Preflight checks for Accessibility + Screen Recording. Never calls `CGRequest*`. |
| `SwitcherPanelController` | NSPanel host. CAShapeLayer mask for antialiased corners. Picks cursor's screen. |
| `HotkeyMonitor` | CGEventTap + NSEvent monitors for Cmd+Tab plus modifier + left-mouse previous-app shortcut. |
| `MRUTracker` | In-memory rank entries that keep windowID, app/title signature, and app identity together; persisted recent bundle IDs (UserDefaults, cap 30). Recovers single-window apps by app identity when ID/title churns; refuses to guess among multiple same-app windows. |
| `PreviewCacheStore` | Two-level LRU (windowID + signature). Capacity 40. Stale-while-revalidate. |
| `ClickOutsideMonitor` | Global + local mouse-down monitors. Closes panel on click outside card. |
| `SwitcherPerformanceMetrics` | Rolling 100-sample p50/p95/p99 for cold-open + first-preview-batch. |
| `LockedValue<T>` | NSLock-backed value cell. Bridges `@MainActor` settings to non-isolated readers. |

## Critical Settled Decisions

See `AGENTS.md` for the full list with rationale. Headlines:

1. No SCStream — user rejected continuous capture pipeline.
2. Soft timeout, not hard — comments are honest that SCKit may ignore cancellation.
3. No `sharingState=0` windows except Microsoft Teams — Teams must remain switchable,
   other private/DRM/autofill surfaces stay filtered.
4. Local signing cert — TCC permissions survive rebuilds.
5. Custom test runner — Xcode not installed, CLT-only toolchain.

## Tests

- Run: `swift run SwitchBladeTests`
- Adding tests: create a file under `Sources/SwitchBladeTests/`, declare
  `static let all: [(name, @MainActor async throws -> Void)] = [...]`, register
  in `main.swift`.
- Mocks live in `TestSupport.swift` (`MockWindowCatalog`, `MockWindowActivator`,
  `MockPermissionService`).
- Per-test isolated UserDefaults via `makeIsolatedUserDefaults()`.
- CI: `.github/workflows/tests.yml` runs on macos-15.

## Conventions

- Finnish UI text via `L10n.tr(.key)`; English code, comments, commit messages.
- Direct-style commits + replies. Lead with the gap. Drop framing verbs.
- Per-window logs use `Logger.<category>` with subsystem `com.jannekammonen.SwitchBlade`.
- `os.Logger` privacy markers: `.public` for IDs and counts, `.private` for window titles.
- Cross-actor non-Sendable types (NSImage, NSEvent) crossed via `@unchecked Sendable`
  wrappers — explicit comment why each one is safe.

## Git

- Check `git status --short --branch` before edits.
- Stage exact files only; never `git add .`.
- Keep commits as logical units. Do not mix memory/docs-only changes with half-finished
  feature code.
- Commit messages should be plain and specific, without over-claiming readiness.

## Workflow Reminders

- After two plausible fixes fail the same live symptom, add diagnostics before
  another heuristic.
- Use scout/reviewer agents for cross-module uncertainty, history checks, and
  test-gap review; keep roles bounded.
- Tests must say what they prove. macOS AX/z-order/TCC behavior still needs a
  signed-app live check when that is the reported failure.
- When verifying hotkey, event tap, activation, UI, signing, or TCC behavior for the
  user, test against the rebuilt signed `dist/SwitchBlade.app`, not only SwiftPM's
  debug binary.

## Known Gaps

- No type-to-filter
- No pin / drag-reorder
- No multi-display per-screen window filter
- No Apple Developer ID + notarization (Gatekeeper warns on other Macs)
- No Sparkle update mechanism
- No crash reporting
- Sleep/wake + screen-params lifecycle observers are NOT unit-tested — only the
  store→catalog half is. Manual integration verification still needed.

## Common Interventions

- **TCC permissions reset after rebuild** → local-signing path broke. Check
  `scripts/setup-local-codesign.sh` output. Should not happen with current setup.
- **Blank previews after idle** → first-batch capture cold-starts. Has retry + soft
  timeout. Check rolling p95/p99 in cold-open log.
- **Switcher feels slow when changing apps** → inspect
  `~/Library/Logs/SwitchBlade/performance.jsonl` first. Compare `hotkey_event`,
  `selection_action_dispatch` / `previous_switch_dispatch`, `panel_show`,
  `capture_previews`, `activation_ax_*`, `activation_app_activate`, and
  `activation_frontmost_observed`; app activation alone is not enough evidence.
- **Window scope feels wrong** → Settings → Behavior → Window scope. Choices are
  current Space, all Spaces, and current app.
- **Permission dialog reappears** → never add `CGRequest*` calls. Use `CGPreflight*` +
  NSAlert that links to System Settings.
- **Single window jumps to switcher tail** → check whether the app recreates its
  window with a new CGWindowID and title. `MRUTracker` should keep rank by
  app identity only when that app has exactly one visible window.
- **All windows of an app jump forward on activation** → verify
  `WindowActivator` targets the selected AX window before calling
  `NSRunningApplication.activate(options: [])`. AX-only activation does not bring
  many apps frontmost; app-first activation can raise sibling windows.
