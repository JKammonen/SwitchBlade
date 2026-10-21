# SwitchBlade — macOS Cmd+Tab Replacement

## Quick Start

```bash
cd /Users/jannekammonen/JK/jkammone/Claude/Repositories/SwitchBlade
bash scripts/build-app.sh             # builds, signs with local cert, emits dist/SwitchBlade.app
swift run SwitchBladeTests            # runs the in-process test suite, exit non-zero on failure
```

On this Mac the CLT default MacOSX27 SDK lacks the SwiftUIMacros plugin (`@State`
fails to expand). Prefix builds and test runs with
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` until that is fixed.

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
| `SwitcherStore` | `@MainActor ObservableObject`. Holds `items`, `selectedID`, `isVisible`. Orchestrates open/commit. The prepared-hidden phase still exists, but the production panel-show delay is 0 since `99a7db7`, so the shipped app shows the panel immediately; delayed-phase tests inject a delay. |
| `WindowCatalog` | `Sendable`. Window enumeration + ScreenCaptureKit capture. Owns `SCContentCache` actor. |
| `SCContentCache` | Actor. Caches `SCShareableContent` with staleness tracking (5 s threshold). |
| `WindowActivator` | `Sendable`. Activate / close / quit / hide. Selected-window activate/snap target the AX window first, then activate the app so the target can become frontmost. |
| `PermissionService` | Preflight checks for Accessibility + Screen Recording. Never calls `CGRequest*`. |
| `SwitcherPanelController` | NSPanel host. CAShapeLayer mask for antialiased corners. Picks cursor's screen. |
| `HotkeyMonitor` | CGEventTap + NSEvent monitors for Cmd+Tab plus modifier + left-mouse previous-app shortcut. |
| `WindowFocusObserver` | One active-app AX observer; captures same-app focused windows before deactivation, with off-main owner-scoped resolution. |
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
  `minimized_window_snapshot` log line from the running PID after its relaunch.
  `check-repo.sh` may defer this interactive
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

- **SwitchBlade unexpectedly quits after Cmd+Q** → the agent's status/application
  Quit menu items intentionally have no keyboard equivalent; explicit menu Quit
  remains available. The visible switcher still uses Cmd+Q for its selected app.
  `isFrontmostApp` is snapshot state: after our panel takes activation, `activate`
  and `snap` must confirm current target-app activation before skipping that
  step. Inspect `activation_focus_restore` for actual state and outcome.
- **Launch or repeated open shows preferences** → SwitchBlade is a quiet
  menu-bar agent (`LSUIElement`, `.accessory`). Launch and
  `applicationShouldHandleReopen` must not open settings automatically, even
  when permissions are missing; recovery remains in the status menu and
  switcher permission footer. Preferences open only through the explicit
  settings action, cannot minimize into the Dock, and are not restorable.
  Closing the last window keeps the agent running. `AppLifecycleTests` and
  the real settings-window construction test cover these contracts; verify
  cold launch, repeated open and manual settings close in the signed app.
- **Fullscreen / Space changes leave old tiles or icon-only cards** → keep the
  intended window scope; switching to all Spaces also admits retained offscreen
  WindowServer surfaces and is not a general fix. `activeSpaceDidChange` now
  invalidates membership, minimized and preview caches, discards old in-flight
  work, and resolves an open switcher again after a 150 ms settling interval.
  Modifier release during that interval waits for a fresh target. Space work
  has a separate task from screen-parameter/wake capture warmups. Diagnostics:
  `active_space_changed` followed by current-scope `window_snapshot` events.
  `com.apple.loginwindow` is excluded in every scope. Do not infer that an
  offscreen row is closed merely because AXWindows is empty: some minimized
  windows use the established remembered-window fallback.
- **TCC permissions reset after rebuild** → local-signing path broke. Check
  `scripts/setup-local-codesign.sh` output. Should not happen with current setup.
- **All previews disappear after a Space change or unlock** → a failed
  `SCShareableContent` refresh after invalidation leaves no content. The capture
  path must still run its existing CG fallback for real requested window IDs,
  with permission, permit and before/after stability checks intact. Do not
  return early merely because SC content is nil. `capture_content_refresh`
  records failure domain/code without private error text; `capture_previews`
  includes `sc_content_available`. `CaptureRecovery/*` tests exercise the actual
  capture path with missing content, private frames and denied permission.
- **Slow previews after idle** → check first-batch latency and retry/soft-timeout
  counts in the performance log before attributing missing images to latency.
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
- **A visible standard window is missing (for example Claude)** → inspect the live
  CG window layer as well as AX subrole/frame. Electron can expose a real main
  window at normal layer minus one (`-1`). `WindowLayerEligibilityPolicy` admits
  that exact layer for enumeration/capture, but listing requires a fresh,
  unambiguous AXStandardWindow frame match within the existing AX scan budget.
  Missing, ambiguous or nonstandard AX evidence excludes it; floating-window
  remembered validation cannot authorize it. Other negative layers remain
  excluded, and current-Space membership and sharing/privacy rules still apply.
  Regressions: `WindowLayerEligibility/acceptsBelowNormalStandardCandidate` and
  `AXWindowEligibility/belowNormal*`.
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
  records hidden warmup retention of missing same-app rows; `cache_order` records the resulting
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
  Every open re-ranks its input with current MRU before choosing the default
  selection or showing the panel, including fresh, stale, and rebased cache
  paths. This reuses cached membership and requires no extra window scan.
  Successful selected-window actions reconcile current/previous app history
  and cached frontmost flags even when an activation notification arrived
  while the panel was still hidden. An already-processed target notification,
  same-app selection, or failed action must not corrupt previous-app history;
  a newer external activation must survive an older action completion.
  `CachedSwitchOrderingTests` covers those paths without real window actions.
  A delayed minimized merge keeps surviving
  displayed rows in their existing relative order and retains selection by ID;
  new minimized rows use MRU insertion positions. An unavailable AX owner may
  retain previously confirmed minimized rows only within their original cache
  lifetime. Fresh rows from that owner or privacy exclusions suppress uncertain
  retention; synthetic rows are also suppressed by fresh visible owner evidence.
  Regressions: `Store/freshOpenUsesMRUBeforeEmptyMerge`,
  `Store/minimizedMergePreservesVisibleOrderAndSelection`, and `MinimizedCache/*`.
- **Switcher returns after modifier release** → compare `panel_hide`,
  `activation_ax_match`, `activation_app_activate`, `selection_action_failed`,
  and the next `panel_show`. An AX target failure can coexist with confirmed
  app activation. Selection uses `WindowActivationResult`: `applicationOnly`
  dismisses the panel and reconciles app history, but does not remember the
  unverified selected window or pin its cached sibling order. The next open
  rebases a single-window cache or refreshes multi-window order. A frontmost
  target with failed AX targeting requires an actual active-app check before
  this partial result; cached frontmost flags alone are insufficient. A
  cross-app `applicationOnly` result records the coarse app hint that an
  external activation would (plus the delayed AX-focus upgrade), so the
  backgrounded window stays the next Cmd+Tab target. Genuine
  activation failures retain the recovery panel; failed snaps remain failures.
  `PartialActivationTests` covers visible/prepared/resolving release, history,
  exact-window MRU preservation, backgrounded-window order, fresh sibling order
  and newer external focus.
- **Is a "selected-target" switch really the chosen window?** → read
  `activation_verification`. `selectedTarget` needs three separate facts:
  confirmed app activation; unique match evidence (complete AX candidate scan,
  every title/frame the rule depends on readable, and the matcher chose the
  `unique-title`, `unique-title-frame` or `unique-untitled-frame` window); and
  that matched AX element observed as the owner process's focused window
  (`matched_element_focus`, 150 ms soft budget, 15 ms polling, no stability
  floor, no corrective raise or retry). Anything else is `applicationOnly`
  with `result_reason`; `legacy_result` shows the pre-verification rule.
  Closest-frame, first-candidate and singleton matches are never unique.
  `matched-element-focused` proves only that the *matched* element got focus,
  not that the match was the selected row. Undetectable with this data model:
  a sibling that took over the selected title (or exact frame when untitled).
  `unknown` (unreadable focused window) is never a mismatch or a success. The
  system-wide AX element is not used: its messaging timeout is process-wide.
  `selection_action_dispatch.queue_ms`/`execution_ms` separate lane wait from
  the action. A completion is stale when any app other than the target (or
  SwitchBlade) activated after the action started, including a return to the
  source app: it then neither calls `rememberSelection` nor rewrites app
  history. PID equality alone missed that return. `activation_request`, all
  off-main activation rows and `selection_action_dispatch`/`_failed` share one
  `correlation_id` (context `selection-<action>` off-main). The double-modifier window
  path inherits the stricter result. Raising has a lower bar than exact
  confirmation: the chosen AX window must itself carry the row's title or a
  frame within 12 pt. Closest-frame/first-candidate guesses are not
  unminimized, raised or focused (`raise_withheld`, reason
  `raise-withheld-*`); the app is still activated. Observed cause
  (2026-10-21): one app's AXWindows listed a single window for three minutes
  while WindowServer showed two current-Space rows, and the old matcher raised
  the listed sibling for the other row. Whether that row was a real window
  omitted by AX or a secondary surface is unresolved. Regressions:
  `ActivationVerification/*`.
- **Cmd+Tab does nothing, or release activates nothing** → look for
  `selection_action_refused`. The single window-action lane stays busy while
  detached AX work finishes, even after `hide()` dropped the caller task. The
  store mirrors the lane in `isWindowActionLaneBusy`; a refused selection is
  handled like a failure (hidden open becomes the visible recovery panel) and
  must never leave the open phase `resolving`, which used to swallow every later
  Cmd+Tab until a Space change. Regressions: `WindowActionLane/*`.
- **New same-app booking/editor enters without a recent window rank** →
  NSWorkspace activation events do not cover focus changes within the already
  active app. `WindowFocusObserver` watches the foreground app's AX focus,
  main-window and creation notifications and captures the actually focused AX
  element before deactivation; creation/main status alone is never focus proof. Its
  retained element is resolved off-main against that owner's eligible CG rows;
  it never re-reads the outgoing app's changed focused-window attribute. Only
  one observation scan runs at a time, and cancelled queued scans do no work.
  `SwitcherStore` records concrete focus history and prefers captured departure
  evidence to a late outgoing-app probe. A newer transition, selected-window
  action, settings or Space change invalidates older results. Native registration
  and focus diagnostics contain PID/window IDs only.
  AX registration can return `cannotComplete` during activation (observed in
  signed Outlook use). `WindowFocusRegistration` retries once after 150 ms,
  cancels on a newer app, and never polls. Successful subscriptions stay active
  while only missing coverage is retried; `window_focus_subscriptions` logs each
  notification's result and `window_focus_observer` logs attempt/duration.
  A focus notification invalidates main-only cached membership immediately,
  including the rebased-cache shortcut; only a scan started after that event can
  clear this invalidation. Initial observation of an already cached window keeps
  the single-window cached fast path; an initially unknown window invalidates
  membership once resolved. Unresolved captures can retry on later notifications;
  an incoming AX upgrade also preserves confirmed departure evidence. Opening
  does not wait for observation resolution and a fresh
  AX-confirmed scan wins over earlier focus history. The matcher must
  verify title/frame even for one enumerated window: enumeration can omit the
  actual focused sibling, so a singleton is not proof of identity.
  Regressions: `WindowFocusHistoryTests` (17 real-scale rows, no native UI),
  `CatalogFocus/focusedWindowMatch_missingFocusedSiblingDoesNotMatchMain`.
- **Source-focus history can use the wrong sibling after panel activation** →
  `pre-activation-backgrounded-focus` runs after panel activation. Preserve
  AX-confirmed focus from the exact fresh visible scan before showing the panel
  using `VisibleWindowSnapshot.focusedWindow`. Bind it to this open/settings
  generation and prefer it for cross-app selection history. An old coalesced
  multi-window scan is refreshed before panel show. Without confirmed pre-panel
  focus, a visible multi-window source must not promote a late AX sibling.
  Cancel/new open/settings/Space discard the capture; failed-action recovery
  retains it for retry. Same-app actions do not background the captured source.
  Tests in `CachedSwitchOrderingTests` await the selection completion diagnostic:
  `!isSwitching` can mean only that the panel hid before its AX action finished.
  Native proof boundary: an authorized two-minute Outlook test of the initial
  observer version reproduced a real unsaved booking falling from slot 0 to
  slot 6/16 after a main-only cached open. The first AX registration had returned
  `cannotComplete`; the later activation registered successfully. A subsequent
  cross-app round trip kept that same booking at slot 1 and activated it exactly.
  This verifies a concrete missing-focus/membership path, not every intermittent
  Outlook case. After renewed explicit window-control permission, the final
  signed producer passed real booking checks: all three Outlook subscriptions
  registered successfully; same-app main-to-booking changes captured each exact
  window; cross-app departure retained the booking and the return selector kept
  it at slot 1 and activated it exactly. The transient registration retry is
  covered by deterministic tests; that transient error did not recur in the
  final native run. This bounded replay does not prove every intermittent case.
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
