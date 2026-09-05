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

Streaming logs (use the full path: `log` is a zsh builtin, so a bare `log show`
or `log stream` fails with "too many arguments" or returns nothing):

```bash
/usr/bin/log stream --predicate 'subsystem == "com.jannekammonen.SwitchBlade"'
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
- No CI: there is no `.github/` workflow. Tests run only locally via
  `swift run SwitchBladeTests`. Run them yourself before handing off; nothing
  runs them on push.
- Minimized/AX risk-surface changes require two separate proofs. The staged-tree
  gate owns deterministic red/green tests and the legacy-limit canary. After the
  signed app is rebuilt and relaunched, use Cmd+Tab once with a safe minimized
  window present, then run `python3 scripts/verify_minimized_runtime_proof.py`.
  The resulting Git-private receipt is bound to HEAD, the staged tree, signed
  bundle source metadata, the versioned producer, and the retained aggregate
  `minimized_window_snapshot` log line. `check-repo.sh` may defer this interactive
  receipt while building, but the shared Git pre-commit gate does not.

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
- **Cmd+Tab falls through to the macOS switcher, then SwitchBlade works again** →
  with performance logging on debug, read `performance.jsonl` around the gap
  before touching tap heuristics. Rows to look for: `hotkey_passthrough` (tap saw
  Cmd+Tab but extra Ctrl or Option flags made the exact-match rule forward it),
  `hotkey_modifier_secure_input` (Cmd pressed while another process held Secure
  Input, so keyDown never reached the tap; carries pid + executable name),
  `event_tap_recovery` (tap was found disabled/invalid and healed),
  `secure_input_state` (Secure Input transitions; `reason` = setup/menu/watchdog).
  With debug logging on, no `hotkey_event` and none of those rows means the
  keyDown never reached the process at all. Known pattern (2026-09-03): tap
  enabled throughout, main thread alive, watchdog quiet, and the blind window
  matched the lifetime of a short-lived foreground process. Details in
  `project_switchblade.md`.
- **Switcher feels slow when changing apps** → inspect
  `~/Library/Logs/SwitchBlade/performance.jsonl` first. Compare `hotkey_event`,
  `selection_action_dispatch` / `previous_switch_dispatch`, `panel_show`,
  `capture_previews`, `activation_ax_*`, `activation_app_activate`, and
  `activation_frontmost_observed`; app activation alone is not enough evidence.
- **Window scope feels wrong** → Settings → Behavior → Window scope. Choices are
  current Space, all Spaces, and current app.
- **Windows land in the wrong order / at the tail** → with performance logging on
  debug, `mru_order` rows in `performance.jsonl` record the reason per window
  (`frontmost`, `rankID`, `rankSignature`, `rankSingleAppIdentity`,
  `persistedBundle`, `snapshotFallback`) plus skipped ranks; `mru_remember` rows
  record each selection commit. `snapshotFallback` = the window had no usable
  rank. os_log debug lines are NOT persisted — jsonl is the only retrospective
  channel.
  Full orders use `row_000000` etc., with at most 32 windows per JSONL chunk.
  Reassemble by `(session_id, event_sequence)` and `chunk_index`; require all
  `chunk_count` chunks and exactly `row_count` rows. The old concatenated
  `order` field was truncated at 256 characters and cannot prove tail order.
  `mru_snapshot` / `mru_order` record input and ranked output; `cache_stabilization`
  records both sides of a cache override; `cache_order` records the resulting
  cache; `display_order` records actual panel show and subsequent list changes
  after selection reconciliation. `open_order` and `prepared_order` alone do not
  prove a visible panel. Follow `open_id` across an open and `correlation_id`
  across a snapshot/focus probe, including coalesced snapshot consumers.
  `frontmost_focus_normalize` reports matched/chosen IDs and unresolved/skipped
  outcomes; `focus_rank_decision` says whether the result was accepted or discarded.
  Sequence and monotonic emission time are captured before asynchronous writes;
  file order and wall-clock write timestamps alone are not causal order.
  Rows contain IDs/state/reasons only. Logging remains debug-only, size-bounded,
  and best-effort: sequence gaps or missing chunks must not be interpreted as
  proof that a window vanished. These diagnostics do not change MRU behavior.
- **Window-targeted self-activation changes a sibling's rank** → capture the
  backgrounded app's exact AX focus before SwitchBlade raises/focuses the target.
  The later app-activation notification must not rescan post-transition AX focus
  for an exact self-initiated window switch; multi-window apps can report a
  different sibling after the programmatic transition. External activations keep
  the delayed AX-focus upgrade path.
- **Permission dialog reappears** → never add `CGRequest*` calls. Use `CGPreflight*` +
  NSAlert that links to System Settings.
- **Single window jumps to switcher tail** → check whether the app recreates its
  window with a new CGWindowID and title. `MRUTracker` should keep rank by
  app identity only when that app has exactly one visible window.
- **All windows of an app jump forward on activation** → verify
  `WindowActivator` targets the selected AX window before calling
  `NSRunningApplication.activate(options: [])`. AX-only activation does not bring
  many apps frontmost; app-first activation can raise sibling windows.
