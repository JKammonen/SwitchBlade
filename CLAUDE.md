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
`bash scripts/build-app.sh`; `.build/debug/SwitchBlade` does not update the app
bundle the user is running. When an instance runs from `dist/`, the script
stops it, publishes, relaunches it and fails unless the new build reports ready
(`Relaunched SwitchBlade on the new build (pid N, ready)`). Launch manually only
when no instance was running.

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
3. `sharingState=0` is normally excluded. Teams and exact-bundle Outlook remain
   switchable; protected Outlook additionally requires a fresh unambiguous standard
   AX window match and normal CG layer, uses a redacted title and never captures pixels.
4. Local signing cert — TCC permissions survive rebuilds.
5. Custom test runner — Xcode not installed, CLT-only toolchain.

## Tests

- Run: `swift run SwitchBladeTests`
- Flake hunting: `SWITCHBLADE_TEST_FILTER=name1,name2` (substring match) and
  `SWITCHBLADE_TEST_REPEAT=N` run selected tests N times. Wait for the event a
  test is about (poll with a bound), never a fixed sleep or an exact count of
  background snapshots: post-hide warmups run on their own timer.
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
  invalidates membership and minimized caches, discards old in-flight
  work, and resolves an open switcher again after a 150 ms settling interval.
  Concrete preview images survive for matching window IDs and owner PIDs in
  the fresh snapshot; previous-Space title/app aliases are cleared. Privacy gates
  still suppress protected windows. Modifier release during that interval waits
  for a fresh target. Space work
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
- **Outlook disappears from the list** → inspect its CG row before restarting.
  A visible standard window can switch to `sharingState=0` while still being a
  valid activation target. The approved exception is exactly `com.microsoft.Outlook`
  on the normal CG layer, with a fresh, one-to-one AXStandardWindow frame match.
  Missing/ambiguous AX proof excludes it. Show only the app name/icon and set
  `canCapturePreview=false`; do not hydrate old pixels. Minimized protected Outlook
  requires a standard AX window and retains the same icon/title privacy boundary.
  `window_snapshot.protected_outlook` counts admitted protected rows.
- **Outlook tile shows only the dark gradient** → a successful capture can be
  fully transparent. In a live comparison, protected mail produced an empty
  whole-window capture while an already-read ordinary message captured normally.
  `PreviewCacheStore.frameQuality` distinguishes fully transparent pixels from
  real translucent content, confirming emptiness at native resolution if the
  small sample is empty. These frames clear every matching cached image and
  suppress stale previews embedded in open-item snapshots until a fresh usable
  capture arrives. The visible tile uses the existing app-icon placeholder.
  Do not force CG recovery for transparent success: it can be content protection.
  `preview_frame_validation.fully_transparent_rejected` records counts only.
  Tests cover empty cache, stale/embedded previews, reopen, recovery, and real
  translucent pixels. This is distinct from timeout/resource recovery below.
- **Display reconnect leaves previews missing** → a populated SC window list and
  a valid recording grant do not prove that SCKit captures complete. Inspect
  `capture_previews.first_timeouts` and `first_resource_limited`. A soft timeout
  retains its SCKit permit until the underlying call returns. `captureWithRecovery`
  skips further SCKit retries on timeout/exhaustion and tries CG fallback through
  an independent process-wide pool (six SCKit + six CG calls maximum). Never
  reset either pool on display changes: blocked calls still own their slots.
  Cancellation and the batch's identity/privacy/geometry/visibility gates still
  apply. `fallback_successes` reports returned fallback images before stability
  rejection. Recovery tests cover timeout, exhausted slots, retry timeout,
  cancellation, and a 25-window snapshot with all SCKit slots occupied. Physical
  display reconnect remains a separate signed-app integration check.
- **Placeholders after idle** → inspect the preceding `active_space_changed` and
  `cold_open.cached_hits`, not just capture timing. A Space notification used to
  clear all previews while hidden warmup recaptured only four: a real 14-window
  open started with four images. Retain bounded concrete-ID/owner preview pixels
  through Space invalidation, clear cross-ID aliases, and hydrate only a fresh
  current-scope snapshot. Settings changes still clear the full preview cache.
  `SpaceChange/retains14VerifiedPreviewsAndRespectsProtection` covers retained
  frames, removed/new rows, same-app aliases and newly protected windows.
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
  For lost recent use, follow `app_activation_received` / `_processed` (including
  suppressed activations), `focus_observer_request` / `_capture`,
  `observed_window_resolution`, `foreground_focus_resolution` and
  `foreground_focus_decision`. Capture resolution and accepted MRU share a
  `correlation_id`; a fallback upgrade names its `parent_correlation_id`.
  `mru_system_activation` distinguishes an unavailable app identity from a
  recorded coarse rank. Debug-only `focus_tracking_sample` compares the actual
  frontmost PID with tracked history once per second, emitting changes and a
  30-second heartbeat without AX/CG scans or history changes. It can miss
  sub-second visits. `selection_focus_ownership` and
  `previous_switch_focus_ownership` expose late completions and activation order.
  Investigation, confirmed loss paths and proof limits:
  [FOCUS_TRACKING_DIAGNOSTICS.md](FOCUS_TRACKING_DIAGNOSTICS.md).
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
  External activations received while resolving/visible still update app
  history and coarse MRU immediately, without reordering the displayed list.
  Their exact AX upgrade waits until idle and the committed action lane is
  free; own panel activation preserves that pending upgrade. Verified selection
  supersedes it without a post-transition sibling scan. A stale completion
  updates neither the selected rank nor its outgoing source rank.
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
  rebases a single-window cache or refreshes multi-window order. An
  unidentified or untargeted row activates its app only when that cannot expose
  an unselected listed sibling: the app had one listed row, or Accessibility
  was unavailable (no identity can exist). Otherwise no activation is attempted
  (`result_reason=activation-skipped-*`, `activation_attempted=false`). A
  cross-app `applicationOnly` result records the coarse app hint that an
  external activation would (plus the delayed AX-focus upgrade), so the
  backgrounded window stays the next Cmd+Tab target. Genuine
  activation failures retain the recovery panel; failed snaps remain failures.
  `PartialActivationTests` covers visible/prepared/resolving release, history,
  exact-window MRU preservation, backgrounded-window order, fresh sibling order
  and newer external focus. Production-reachable `applicationOnly` shapes are in
  `ActivationVerification/*` (unreadable focus, single-row and no-Accessibility
  fallback).
- **Selected window opens a sibling (all apps)** → concrete actions use the
  selected WindowServer ID within its owning process. `AXWindowIdentity` resolves
  `_AXUIElementGetWindow` once through `RTLD_DEFAULT` (undocumented macOS API;
  `ActivationVerification/windowIdentitySymbol_resolves` checks the real export).
  A missing symbol, unreadable ID, absent target or duplicate match raises
  nothing; app activation then follows only the single-row/no-Accessibility
  fallback above. Title/frame matching is reserved for synthetic minimized rows,
  and requires unique evidence over a complete readable AX list before raising.
  Concrete matching reads IDs only, avoiding unrelated title/frame AX timeouts.
  `selectedTarget` additionally requires confirmed app activation and focus of
  the retained matched AX element. If activation restores a different sibling,
  one corrective raise/main/focus is allowed only for the same retained exact-ID
  target, while its app remains active and its ID can still be read. No rematch,
  no app reactivation loop. Only an observed *other* focused window with several
  listed rows returns failure and the recovery panel. Unreadable focus (signed
  Outlook returned AX `cannotComplete` -25204) or a later departure is
  `applicationOnly`: the panel stays dismissed and the intended row is not
  promoted in MRU.
  `activation_verification` logs `match_evidence_basis=window-id`, focus and
  `focus_restored_after_activation` without window titles. Action correlation
  and stale-completion guards remain in force. Synthetic rows lack concrete ID
  continuity; their unique title/frame match is a weaker documented limit.
  Regressions: `ActivationVerification/*` includes 14 overlapping untitled
  windows, contradicted titles, missing identity and activation focus reset.
  Injected candidates use the production rule: concrete targets match by
  window ID only, so title/frame evidence tests use synthetic minimized IDs.
- **A window lookup fails (`ax-targeting-failed`, `no-match`) or falls back
  to app-level** → read `activation_ax_match` (debug logging only, diagnostic
  only: no retry, no stale-element repair). Every activate/close/snap lookup,
  matched or not, records `lookup_action`, `window_list_outcome`
  (`read-failed`, `unexpected-type`, `empty`, `listed`) with the raw
  `window_list_error`, `candidate_total` / `candidate_count` /
  `candidate_scan_bounded`, `identity_success_count`, `identity_error_counts`
  (`code:count`, `-2147483648` = identity symbol missing), `target_identity_found`,
  `other_identity_count`, `process_alive_at_start` / `_at_end` and
  `windows_ms` / `candidates_ms` / `decision_ms`. A ~250 ms duration alone is
  not proof of `cannotComplete` or a busy app; a dead process or stale target
  can look alike. Open case (2026-11-04, pre-diagnostic build): ChatGPT failed
  13 single-row lookups in about 0 ms and an exited app 4 lookups in about
  250 ms; both used the single-row app fallback. A bounded retry is to target
  only the error these rows prove. First run: 25/25 lookups clean; Finder lists
  one AX window whose identity read returns -25201 (likely its desktop window,
  inferred). Regressions: `WindowLookupDiagnostics/*`.
- **AX calls fail with -25211 (`APIDisabled`) for apps started after a rebuild**
  → the bundle was replaced under a running instance. Proven 2026-11-05 by a
  controlled repeat: after `build-app.sh` replaced `dist/` under a running
  instance, an app launched afterwards answered every AX call from it with
  -25211 while a shell read it normally; apps contacted before the swap kept
  working; a relaunch fixed the same target process (Teams in a meeting: 14
  failed selections). The macOS mechanism behind it is inferred.
  Design (after an app-driven relaunch protocol failed two independent
  reviews): **`build-app.sh` owns publication and the instance lifecycle**
  (`scripts/relaunch-lifecycle.sh`, `switchblade_publish`). Under the signing
  lock it finds a running instance by exact argv path (given and physical
  spelling) and by the ready marker
  (`~/Library/Application Support/SwitchBlade/ready`: pid, mapped executable
  inode, time) whose live process maps the published file, so relative argv,
  symlinks or letter case cannot hide it. It SIGTERMs it, waits (SIGKILL after
  10 s; if it survives, the bundle is not replaced), swaps the bundle, `open`s
  it (one retry with `open -n`) and accepts success only from a fresh marker
  naming a live process that maps the new file; otherwise the build fails.
  Once an instance was stopped, a failed swap restarts the previous build and
  an interrupted or failing script restarts the published one (EXIT trap). It
  never starts SwitchBlade when none was running (`SWITCHBLADE_NO_RELAUNCH=1`
  stops without restarting and says so). The app side (`InstanceLifecycle`):
  - `instance.lock` (`flock`, close-on-exec) first in launch, before any
    monitor, tap or hotkey; `open -n`/direct exec exits (`singleton_rejected`).
    It also takes a fallback lock in `NSTemporaryDirectory`, so an instance
    that could open only the fallback still excludes a later one. If neither
    opens it runs unlocked and records `singleton_lock_unavailable`. The
    SIGTERM handler is installed right after the lock.
  - SIGTERM quits gracefully once idle (no switcher, no window action), at
    most 3 s; `applicationWillTerminate` writes the rank handoff
    (`relaunch-handoff.json`: window ID, owner PID and start time, app identity;
    no titles). Every MRU rank is handed over in order: concrete windows with
    owners from WindowServer's full list (minimized and other-Space windows
    keep rank), synthetic minimized rows with the owner the switcher knows
    (restored only if that process kept its start time), app-level ranks as
    app identity. The next launch consumes it once (< 120 s, same boot).
  - Previews are never persisted, so every launch (also each relaunch by the
    script) warms previews for every capturable window in scope, not the
    routine four: the first open after a relaunch showed 4/12 cached before.
  - The ready marker uses the kernel's mapped-image inode
    (`LaunchIdentity.capture()` first in `main`).
  - A replacement outside the script cannot be prevented: it is detected
    (`bundle_replaced_while_running`) and the status item shows a restart
    action until restarted. Running from `swift run` skips all of this.
  Regressions: `Relaunch/*`; `scripts/test-relaunch-lifecycle.sh` (in
  check-repo and run-deterministic-tests) drives the real publish sequence with
  a compiled fake app (not a `.app`, fake `open`): relative-argv identity, stop
  before swap, no start without an instance, unready build fails, failed swap
  restarts the previous build, SIGTERM-ignoring instance, corrupt marker,
  interrupted publication.
- **Switch reported success but the window did not appear** → read
  `activation_outcome_probe` (debug logging only, diagnostic only: no behavior
  change). About 150 ms after a completed `activate` selection, off the action
  lane, it records `target_on_screen`, `target_app_frontmost`, `frontmost_pid`
  and the normal-level windows (layer 0 and the Electron layer -1) listed above
  the target that overlap it: `covering_other_app_count`,
  `covering_same_app_count`, `covering_max_fraction`, up to 8
  `covering_window_ids` / `covering_owner_pids`. SwitchBlade's own panel and
  fully transparent surfaces are excluded; titles are never read. It shares the
  selection's `correlation_id`. A newer open or selection, an open switcher, or
  an activation of another app discards it as
  `activation_outcome_probe_discarded` (`superseded`, `switcher-open`,
  `user-departed`, `departed-before-completion`). Open case (2026-11-04): a
  `selectedTarget` result whose workbook did not appear; a clean retry opened
  it. Covering is a hypothesis, not a finding, until this row shows it. First
  signed-app run (43 selections, 7 apps incl. two Excel workbooks): 0 covered
  or off-screen targets and one real `superseded` discard. The
  double-modifier window path is not probed. Regressions:
  `ActivationOutcomeProbe/*`.
- **New window missing immediately after launch/open (all apps)** → cache age
  is not proof of membership. Every cached open paints immediately, then
  reconciles a scope snapshot started after that open, including additions and
  removals. Cold opens also reject a pre-open in-flight warmup snapshot.
  New opens/settings supersede old reconciliation; previews remain cached and
  current-Space/privacy filters still apply. Until the user moves the
  selection, reconciliation keeps the default *position* (slot 2, the previous
  window); afterwards it keeps the chosen window by ID. Live cause 2026-11-04:
  a relaunched Outlook window appeared first and the retained stale default
  slid to slot 3. A cache with no row (or several rows) for the frontmost app
  is not used at all: its slot 2 is not the previous window, so even a quick
  release waits for a fresh scan (about 5% of opens, p50 ~43 ms). A selection or `hide()` discards the pending reconciliation:
  its scan predates the selection, so it must not rewrite the selection-synced
  cache (frontmost flags, resnapshot marker); post-hide warmups refresh it. An
  empty scan (also the CGWindowList failure result) keeps the painted rows.
  Only rows whose every scanned fact is unchanged (`hasSameScannedState`: ID,
  owner, title, frame, frontmost/minimized and privacy state) keep the in-flight
  preview batch instead of restarting capture; equal IDs alone are not enough,
  because a window can turn protected without a new ID and hydration must drop
  its pixels and title (`stale_heal_discarded`, `display_order` context
  `stale-cache-refresh-unchanged`). A window not yet created/eligible at snapshot time can only be
  discovered by a later notification/open. Regressions:
  `CachedSwitch/freshCacheDiscoversNewAndClosedWindows` (14 rows),
  `CachedSwitch/healAfterQuickCommit*`, `emptyHealSnapshot*`, `unchangedHeal*`,
  `sameIDHealAppliesProtectedState*`, `healInsertingFrontWindow*`,
  `healAfterUserMove*`, `frontmostAppWithoutCachedRow*`,
  `Store/requestCycle_doesNotReusePreOpenWarmupSnapshot`.
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
  A successful registration does not guarantee a successful focused-window
  read: signed Outlook callbacks also returned `cannotComplete` (-25204).
  `WindowFocusReadRecovery` retries only that read error, at most three times
  after 150/350/700 ms. One sequence is shared by all notification kinds;
  newer notifications supersede it. Each read checks foreground PID and store
  eligibility before and after AX IPC. Observer changes, panel opening and
  either window-action lane cancel pending reads, including same-PID actions.
  Capture retains the exact AX element; main/created windows are never inferred
  as focused. Subscription-only registration retries do not start another read
  after an existing observer was attached. `focus_observer_capture` includes
  attempt, correlation, AX error, cancellation and exhaustion without titles.
  Regressions: `WindowFocusReadRecoveryTests` includes 19-row history and a
  same-app action race. Deterministic recovery is verified; the intermittent
  native Outlook failure must recur to prove that path in the signed app.
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
