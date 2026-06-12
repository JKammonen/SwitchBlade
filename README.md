# SwitchBlade

SwitchBlade is a macOS Cmd+Tab replacement focused on per-window switching,
MRU ordering, ScreenCaptureKit previews, Accessibility-based activation, and a
small signed app bundle.

## First Read

- `AGENTS.md` - repo rules, settled ScreenCaptureKit/AX decisions, verification
- `CLAUDE.md` - module inventory and detailed local guidance
- `ARCHITECTURE.md` - stable component boundaries
- `DECISIONS.md` - durable project decisions

## Run And Build

```bash
bash scripts/build-app.sh
open dist/SwitchBlade.app
```

The app requires the expected macOS permissions for screen capture and
accessibility behavior.

## Check

```bash
bash scripts/check-repo.sh
```

`swift build` alone is not enough for user-tested behavior. Rebuild the signed
app bundle when validating the actual app path.
