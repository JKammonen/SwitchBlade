# Focus history investigation — 2026-10-23

The original patch diagnosed lost recent-window use without changing history.
The subsequent correction below addresses the two independently reproduced
defects. No sorting heuristic or additional window activation is introduced.

## Correction after diagnosis

External activation now records current/previous app and coarse MRU even while
the switcher is visible/resolving; the activation callback does not reorder the
displayed rows or change the selected ID.
Only exact AX focus resolution is deferred. The latest deferred PID resumes
after the panel closes and the committed action lane is free. Own panel
activation does not consume it; a newer external app replaces it. A verified
selected-window completion supersedes it without rescanning a potentially
different sibling. A failed action retains it until recovery is dismissed.
Original pre-panel source evidence is cleared by external use, including a
return to the same PID, so it cannot masquerade as a current source capture.
Older snapshot results cannot reinstall that source while the external focus
upgrade is pending. The pending visit is retained until an exact focus is
accepted or a newer action supersedes it; reopening before the delayed probe
runs therefore cannot consume the visit. The rapid-reopen regression exercises
the rejected first probe followed by successful resolution after another cancel.

`completeSelectionAction` now gates both the selected window and the outgoing
source on `selectionStillOwnsFocus`. Stale outgoing evidence is logged as
`discarded-stale-action`; `backgrounded_rank_will_update` reflects this gate.

The regression tests were run before the production correction: resolving
cancel, visible activation and superseded deferred focus failed, and the
strengthened return-to-source test reproduced `[1,2,3] -> [2,1,3]`. Added held
action tests cover successful selection replacing the pending AX upgrade and
failed selection retaining it through recovery. Verification results for the
corrected signed build are recorded separately below.
The new fixture supplies bundled-app identity through the store's injected
lookup and uses PIDs above the host range; otherwise a test PID can accidentally
resolve to Dock/NotificationCenter or supply no identity for a real-app scenario.

## Incident evidence

The running signed process was PID 6347, launched on October 21. Its build's
source tree `b34f7cf5db02f04ec36715aaa81e0ef7c1a7823b` differs from HEAD
`a7f3e7f` only in `CLAUDE.md`; production code matches. Codex's host PID was
34098 (`com.openai.codex`), and its concrete window ID was 113471.

The complete 19-row `display_order`, event 145391, on October 23 at
13:31:28 Europe/Helsinki places that window at index 10. Its MRU binding is
still an exact `rankID`, rather than `snapshotFallback` or an identity guess.
The last Codex history write before that open was event 142939 at 13:11:48.
No event with a top-level `pid` or `selected_pid` of 34098 occurs between those
events. The user reports having just used Codex. This is a conflict between
reported real use and recorded history, not proof that the old instrumentation
observed every macOS notification.

Every preceding row has a later MRU write than Codex. Thus the displayed order
follows the recorded history; changing sort order would conceal the missing
observation. In that open the list already has the middle position before any
minimized merge. The current and rotated logs are bounded, best-effort evidence;
they cannot retrospectively distinguish an absent OS notification from a
silently ignored notification/capture.

## Original defects and remaining alternatives

1. **External activation while switching can leave tracking on the old app.**
   The original `handleAppActivation` increments the activation sequence, but skips current
   app, MRU and incoming focus upgrades while visible/resolving. It then asks the
   observer to observe the old current PID. `hide`/`cancel` do not reconcile the
   actual foreground app. Later captures for the newly used app fail the PID
   guard. The 19-window regression is now named
   `FocusDiagnostics/externalActivationAcrossCancelKeepsTracking`; it requires
   the used window to become most recent, then remain second after departure.
   `visibleActivationDefersOnlyExactFocus` covers the visible variant.

2. **A stale selection completion still promotes its outgoing source.**
   The original `completeSelectionAction` protects the selected window with
   `selectionStillOwnsFocus`, but applies `trackBackgroundedWindowFocus` without
   that condition. An isolated archive of unmodified HEAD behavior reproduced
   `[1, 2, 3] -> [2, 1, 3]` after a return to the source. The only adversarial
   fixture addition to `storeReturnToSourceIsNotOverridden` was making the
   source probe resolve (`catalog.focusedWindowItemsByPID[100] = crossAppWindows[0]`).
   The original fixture leaves that probe unresolved and misses the branch.
   The verified-selection control passed. This proves a separate MRU defect,
   not its occurrence in the reported Codex incident.

3. **Captured focus can finish after the state gate closes.**
   `handleWindowFocus` cancels the incoming upgrade, begins resolution, then
   discards its result if a panel/action/new capture has intervened. There is no
   replay on the switching/action discard path. The diagnostic test
   `resolutionDiscardedDuringOpenKeepsCorrelation` exercises that boundary.
   Source departure may legitimately consume the retained capture, so a discard
   alone is not proof that all history for that visit was lost.

4. **AX capture/identity failures remain possible.** Successful registration
   means at least one subscription worked; created-only coverage cannot observe
   all existing-window focus changes. Bounded retry may leave missing focus
   coverage until another registration request. Capture can also fail before
   resolution, or title/frame/CG matching can fail. A system activation without
   either a bundle ID or a live cached owner cannot record even a coarse rank.
   These alternatives now have distinct diagnostic fields; none is proven for
   Codex by the retained incident logs.

5. **Previous-app modifier actions have another stale-completion risk.** The
   window, app and cached app routes update history after awaiting activation
   without the selection route's newer-activation guard. New ownership events
   expose their start/current sequence and tracked/actual PIDs. This is a source
   finding, not a reproduced incident or an independently verified live defect.

## Diagnostic chain

| Event | Discriminating information |
|---|---|
| `app_activation_received`, `app_activation_processed` | Incoming PID, phase, actual/tracked PID, activation sequence, suppression reason, requested observer PID, exact self-activation target |
| `focus_tracking_phase` | Old/new phase plus tracked/actual PID and action state |
| `focus_tracking_sample` | Actual/tracked PID mismatch independent of activation callbacks; nominal 1-second sampling, changes and 30-second heartbeat |
| `focus_observer_request` | Desired/registered PID, pending retry, stop/register/unchanged |
| `window_focus_subscriptions`, `window_focus_observer` | Per-notification coverage, registration result and bounded retry |
| `focus_observer_capture` | Notification kind, actual PID before/after AX, AX error, absent/wrong value, captured/discarded |
| `observed_window_resolution` | Owner lookup, candidate count, title/frame availability, matched ID, failure classification and timing |
| `foreground_focus_resolution`, `foreground_focus_decision` | Resolution/cancellation and exact receive/completion gate; one correlation ID |
| `focused_ax_read`, `focus_rank_scheduled`, `focus_rank_decision` | Fallback AX failure and upgrade acceptance; retry points to parent capture |
| `mru_system_activation`, `mru_remember` | Coarse identity availability and concrete history write |
| `selection_focus_ownership`, `previous_switch_focus_ownership` | Newer activation since operation start, current/actual PID; selection also reports whether the outgoing source will still be promoted |
| `mru_order`, `display_order` | Rank reason and actual visible result; reassemble all chunks |

All added production diagnostics use the existing debug-only, bounded JSONL
writer. They contain IDs, state, counts, availability flags, errors and timing;
no titles, app display names or images. The sampler does not query AX or CG and
does not mutate MRU. It stops when debug logging is disabled and is started on
launch/next activation/open when enabled. A busy main actor can delay samples;
sub-second visits and best-effort writer drops remain possible.

## Verification boundary

`FocusTrackingDiagnosticsTests` now guards the corrected activation/cancellation
paths and checks receive/completion correlation, private-text exclusion and
bounded non-mutating sampling. The diagnostic-only baseline below predates
the production correction.
The pending-departure history fixture now seeds live identities: its artificial
PIDs have no real bundle lookup, so the old fixture raced the incoming concrete
upgrade against a missing coarse app rank. This is fixture preparation, not a
production ordering change.

Signed-app startup and real diagnostic output must be checked after rebuilding
and relaunching. Neither passing tests nor a short aligned sample proves the
intermittent Codex incident fixed. To attribute a later occurrence, distinguish
missing activation receipt, suppressed receipt, failed AX capture, rejected
completion and a later stale history write using the chain above.

### Completed checks for the diagnostic-only baseline

- Latest source: 562/562 Swift custom-runner tests passed; the seven Python
  runtime-proof verifier tests passed. This is not a claim that the unchanged
  intermittent behavior or every repository release gate passed.
- Stable local signing and strict signature verification passed. The user
  keychain search list remained the single login keychain.
- Rebuilt bundle timestamp: `2026-10-23T10:55:27Z`, marked `working-copy` because
  the diagnostic source changes are uncommitted/unstaged. The metadata's Git
  source tree names the unchanged index, not the diagnostic source content.
- The relaunched signed PID 63055 started at 13:56:56 Europe/Helsinki, after
  the build timestamp. No test windows or focus-switch series were needed.
- At 13:56:56–13:56:58 its startup observed Codex PID 34098/window 113471:
  `focus_observer_capture` -> `foreground_focus_decision` received ->
  `observed_window_resolution` matched (one candidate, title/frame available)
  -> `foreground_focus_resolution` resolved -> decision accepted ->
  `foreground_window_focus` -> `mru_remember`. All use correlation
  `B3C331C4-94CF-4A5F-B5E4-C23A977BD931`. The independent sample reported
  tracked/actual PID 34098 aligned. This verifies the real Codex diagnostic
  path, not recovery of the lost historical visit.
- Passive observation of subsequent normal use also recorded external returns
  to Codex at 13:57:49 and 13:57:54: activation received, observer capture,
  matching window 113471, accepted focus and correlated MRU writes. No injected
  window-switch test was used. These successful samples do not reproduce or
  eliminate the intermittent loss paths above.

### Completed checks for the two production corrections

- Before correction: the strengthened suite failed the resolving/cancel,
  visible activation, superseded deferred focus and stale outgoing-source
  regressions. The stale case explicitly reproduced `[1,2,3] -> [2,1,3]`.
- Final corrected source: 567/567 custom Swift tests passed, including held
  successful/failed actions, rapid reopen and A1 -> B -> A2 while an older
  snapshot is resolving. The seven Python verifier tests also passed.
- Stable local signing and strict signature verification passed. The exact
  before/after keychain search-list bytes match; only login remains listed.
- Corrected bundle timestamp: `2026-10-23T11:19:16Z`; the running signed PID
  75864 started at `2026-10-23T11:21:07Z` (14:21:07 Europe/Helsinki) from this
  repository's `dist/SwitchBlade.app`. Source state is `working-copy`; unchanged
  checksums of all four edited production files bind the build input. The
  source-tree metadata still describes the Git index, not unstaged content.
- Real startup in Outlook PID 48583 captured/matched window 123484, accepted
  it and wrote MRU under correlation
  `E4DB3367-7D67-42C5-9221-876DBBA18B5E`; tracked/actual PIDs aligned. This
  verifies the deployed path, not an injected reproduction of either race.

## Additional Outlook report during the build

The user reported an Outlook message window moving backward before the corrected
binary was launched. The executing process was still diagnostic-only PID 63055;
the fixed binary was built but had not yet replaced that process.

This retained trace shows a separate concrete observation failure:

- At 14:19:38.994–14:19:40.385 Europe/Helsinki, five Outlook focus/main/created
  callbacks failed the AX-focused-window read with `cannotComplete` (-25204).
  Unlike the activation/cancel defect, the observer was on the correct PID and
  received notifications; it could not obtain a window to resolve/rank.
- At 14:19:44.872, the complete actual `display_order` (event 6662) contains
  older Outlook window 105247 at index 0 and new window 123484 at index 11.
  The new window's reason is `persistedBundle`, not a concrete per-window
  rank. At 14:19:45.568 (event 6741) it appears at index 13. Fresh AX
  normalization at 14:19:44 matched the older window, not the new one.
- The incident binary's callback read-error branch had no capture retry. There is therefore a
  supported mechanism for a newly used window to remain unranked. The log
  does not identify which window held actual user focus during those failed
  reads, so it cannot prove that merely retrying would recover the message
  window or that later AX would report the right sibling.

The two corrections above did not change that native AX read-error path.

## Focused-window read recovery

`WindowFocusReadRecovery`, used directly by the native observer, now retries
`cannotComplete` up to three times, after 150/350/700 ms (initial read plus
three retries). Other AX errors, absent values and wrong value types stop.
This provides a bounded recovery opportunity; it does not guarantee Outlook
will become responsive or report the originally missed window.

- Before and after every read, the observed PID must still be foreground and
  the store must permit capture. A generation check rejects a read cancelled
  during AX IPC. The result retains exactly the AX element read while foreground.
- A new notification supersedes pending recovery. Observer changes, opening
  the selector and both action lanes cancel it, including same-app actions.
  A blocked attempt never resumes by itself when an action finishes.
- A subscription-only registration retry maintains coverage without initiating
  a new focus read on an already attached observer. This prevents it bypassing
  action cancellation after that action completes.
- Attempts share a correlation through the accepted capture and MRU record.
  Capture diagnostics include bounded attempts, retry delay, error, cancellation
  reason and terminal exhaustion. No window titles or contents are added.
- `WindowFocusReadRecoveryTests` exercises recovery, exhaustion, permanent and
  malformed reads, departure before/during AX IPC, reentrant cancellation,
  supersession, membership invalidation, 19-row history, selector cancellation,
  same-app action races and privacy of the actual diagnostic payload.

Native proof boundary: the incident trace proves the error path existed. Tests
exercise the production recovery driver with injected reads and the real store;
they do not force the transient Outlook AX failure. Successful normal reads in
the signed app do not prove that every intermittent Outlook ordering case is
resolved. No focus identity is inferred from main/created notifications or
from a recovery read after departure.

Verification on 2026-10-23: the final custom suite passed 581/581 tests in
21.23 s. The rebuilt bundle passed strict signature verification with the
existing local certificate; 82 source/build/test input hashes stayed unchanged
through the build, and the user keychain search list remained byte-identical.
Old PID 75864 was stopped. New PID 91291 started at 14:41:39 Europe/Helsinki
from this checkout's `dist/SwitchBlade.app`; its mapped executable path was
checked. The new native observer captured and accepted one exact window with
one shared correlation. That normal read does not exercise Outlook's transient
failure. Evidence is retained under the path in
`/tmp/switchblade-focus-read-evidence-path`.
