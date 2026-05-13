# SwitchBlade — macOS Cmd+Tab Replacement

## Quick Start

```bash
cd /Users/jannekammonen/JK/jkammone/Claude/Repositories/SwitchBlade
bash scripts/build-app.sh             # builds, signs with local cert, emits dist/SwitchBlade.app
swift run SwitchBladeTests            # runs the in-process test suite, exit non-zero on failure
```

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
   MRUTracker  (in-memory recent IDs + persisted recent bundle IDs)
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
| `SwitcherStore` | `@MainActor ObservableObject`. Holds `items`, `selectedID`, `isVisible`. Orchestrates everything else. |
| `WindowCatalog` | `Sendable`. Window enumeration + ScreenCaptureKit capture. Owns `SCContentCache` actor. |
| `SCContentCache` | Actor. Caches `SCShareableContent` with staleness tracking (5 s threshold). |
| `WindowActivator` | `Sendable`. Activate / close / quit / hide. Pure AX + NSRunningApplication. |
| `PermissionService` | Preflight checks for Accessibility + Screen Recording. Never calls `CGRequest*`. |
| `SwitcherPanelController` | NSPanel host. CAShapeLayer mask for antialiased corners. Picks cursor's screen. |
| `HotkeyMonitor` | CGEventTap + NSEvent monitors for Cmd+Tab. |
| `MRUTracker` | In-memory recent IDs + persisted recent bundle IDs (UserDefaults, cap 30). |
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
- **Window scope feels wrong** → Settings → Behavior → Window scope. Choices are
  current Space, all Spaces, and current app.
- **Permission dialog reappears** → never add `CGRequest*` calls. Use `CGPreflight*` +
  NSAlert that links to System Settings.
