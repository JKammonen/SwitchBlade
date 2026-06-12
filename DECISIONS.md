# SwitchBlade Decisions

## 2026-06-12: Keep project ownership docs in the repo

- Decision: root `README.md`, `ARCHITECTURE.md`, `DECISIONS.md`,
  `AGENTS.md`, and `scripts/check-repo.sh` are the minimum local ownership
  surface.
- Why: macOS permission, signing, capture, and activation behavior needs a
  durable repo-local explanation.
- Verification: `scripts/check-repo.sh` is the local check entrypoint, and the
  shared infra audit checks that this ownership surface exists.

## Settled Working Decisions

- No `SCStream`. Use per-call `SCScreenshotManager.captureImage`.
- Capture timeout is soft, not hard.
- Do not include `sharingState=0` windows except Microsoft Teams.
- Use a local signing certificate, not ad-hoc signing.
- Use the custom test runner: `swift run SwitchBladeTests`.
- Wake/screen-parameter changes need invalidation plus warmup.
- Selected-window activation is AX-targeted before app activation.
- Build scripts must not leave the global user keychain search list modified.
