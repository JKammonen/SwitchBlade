# SwitchBlade Architecture

## Boundaries

- `Sources/SwitchBlade/AppMain.swift` is the thin executable entrypoint.
- `Sources/SwitchBladeCore/` owns all production logic.
- `AppDelegate` owns application lifecycle and top-level wiring.
- `HotkeyMonitor` owns global hotkey capture.
- `WindowCatalog` and related capture/cache types own window discovery and
  preview acquisition.
- `MRUTracker` and `SwitcherStore` own ordering and state transitions.
- `SwitcherPanelController`, `SwitcherLayoutCalculator`, and `SwitcherView`
  own panel presentation and layout.
- `WindowActivator` owns AX-targeted activation.
- `PermissionService` owns permission state and prompts.
- `Sources/SwitchBladeTests/` is a custom Swift executable test runner, not
  XCTest or swift-testing.

## Runtime Shape

The app listens for the configured hotkey, refreshes the visible window model,
orders windows by per-window MRU state, shows a switcher panel with previews,
and activates the selected AX window before falling back to app-level behavior.

## Verification

- Main local test gate: `swift run SwitchBladeTests`.
- User-tested behavior gate: `bash scripts/build-app.sh`, quit old process,
  launch `dist/SwitchBlade.app`, and verify the live app path.
- Diagnostics must avoid logging window titles or preview contents by default.

## Ownership Rule

Signing, keychain, TCC, ScreenCaptureKit, and AX decisions belong in repo docs
or targeted positive-memory files. Do not leave them only in chat history.
