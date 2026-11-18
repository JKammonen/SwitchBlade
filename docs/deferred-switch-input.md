# Deferred switching input

A Cmd+Tab accepted by the event tap must not disappear merely because a previous
native window action still owns the serialized lane. This is a bounded change to
the current `SwitcherStore`, not SwitchingCoreV2 integration.

## Rules

- Track one pending navigation delta/press count and the first input timestamp.
  The HID tap normalizes hardware tick timestamps and uptime-nanosecond timestamps
  to uptime nanoseconds before measuring queue delay or starting the deadline.
- Accept input while either `windowActionTask` exists or the native lane is busy,
  including a cancelled task whose detached work has not returned yet.
- Track modifier release while pending. At resume, live flags for the configured
  modifier win over the recorded edge. Reconcile monitor release tracking and
  reject a delayed old up event while the live modifier is re-pressed.
- Expire after 400 ms from the first pending key event. Check again before a
  delayed snapshot can auto-activate. Once a real new gesture owns an opening,
  it follows the normal open lifecycle rather than the old recovery restriction.
- Success (including selection `applicationOnly`): use normal opening with the
  accumulated delta. A live held modifier opens normally; an already released
  modifier uses `enterResolving(commitWhenReady: true)`.
- Selection failure/refusal: move selection in the recovery panel, never
  auto-commit an already released pending input.
- Modifier+click/double-modifier failure (including window `applicationOnly`):
  open through the normal existing panel states. Held opens normally and its
  later release commits; already released opens for click/Enter/Esc recovery.
- Resume only after the owner completion updates history/cache, not inside the
  lane-release defer. Exact previous-window selection synchronizes its cached
  order; app-only previous switching marks membership for normal rebasing.
  No post-success AX focus read is introduced.
- A cancelling hide, settings/Space change or observed unrelated app activation
  discards pending input. Cancelling during deferred opening also aborts that
  opening. A genuinely new input after a cancelling hide waits for the old lane
  and opens from normal fresh membership without adopting a cancelled result.
- Hidden Esc is not intercepted. No new global key or mouse interception exists.

`hotkey_deferred_action_in_flight` records age, press count, signed cycle delta,
release state and outcome (queued, resumed, expired, cancelled). It uses the same
privacy-safe performance logging policy as existing hotkey metrics.

## Verification

`DeferredInputTests` exercises the outcome table through public store paths with
slow native mocks: selected/app-only results, failed/refused recovery, all three
previous-switch implementations, live modifier contradictions, navigation/Shift,
expiry, cancelled lanes, and cancellation before/after opening. Refusal is tested
using an actually occupied injected `WindowActionCoordinator`. Monitor tests
cover delayed up after re-press. Older busy-lane tests now assert waiting followed
by normal quick release instead of the former refused-action recovery behavior.

The input-dropping branch was restored temporarily in this isolated worktree and
the new success-order regression failed; the corrected implementation was then
restored. This proves removal of the demonstrated input-loss policy. It does not
establish its frequency in ordinary user activity.

The existing preview-cache fixes remain separate changes. No commit or push is
authorized by this implementation task.
