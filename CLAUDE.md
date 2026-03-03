# CLAUDE.md — Blackout

## What This App Does

macOS menu bar app that covers all screens with a black overlay. Two unlock methods: **hotkey** (toggle shortcut) or **password** (type secret to dismiss). Includes triple-Escape emergency dismiss, sleep prevention, and opacity adjustment.

## Build

IMPORTANT: Uses `swiftc` directly — NOT `xcodebuild` or `swift build`.

```bash
cd ~/Documents/Tools/black-screen
mkdir -p Blackout.app/Contents/{MacOS,Resources}
cp Blackout/Info.plist Blackout.app/Contents/Info.plist
cp Blackout/AppIcon.icns Blackout.app/Contents/Resources/
swiftc -o Blackout.app/Contents/MacOS/Blackout \
  Blackout/main.swift Blackout/AppDelegate.swift Blackout/OverlayManager.swift \
  Blackout/HotkeyManager.swift Blackout/SetupWindowController.swift \
  Blackout/SleepPrevention.swift Blackout/PasswordMatcher.swift \
  -framework Cocoa -framework Carbon -framework ServiceManagement
```

When adding new `.swift` files, add them to the `swiftc` command above AND update the README build section.

## Deploy

```bash
rm -rf /Applications/Blackout.app
cp -r ~/Documents/Tools/black-screen/Blackout.app /Applications/Blackout.app
```

## After Code Changes

Always: build → commit → push → copy to /Applications (replacing the existing app).

## Architecture

All source lives in `Blackout/` (flat, no nested modules). `Blackout.app/` is committed as pre-built distribution.

| File | Role |
|------|------|
| `main.swift` | Bootstrap — creates NSApplication + AppDelegate |
| `AppDelegate.swift` | Central orchestrator: menu bar, hotkey/password routing, setup delegation |
| `OverlayManager.swift` | Creates/manages fullscreen black windows, focus guard, local key monitor, opacity control |
| `HotkeyManager.swift` | Global hotkey via Carbon API, triple-Escape detection, key display strings |
| `SetupWindowController.swift` | Guided wizard (mode select → capture → confirm → practice → done) |
| `PasswordMatcher.swift` | Character-by-character password validation + KeychainHelper (UserDefaults storage) |
| `SleepPrevention.swift` | IOKit assertion to prevent display sleep while overlay is active |

## Key Design Decisions

- **No accessibility permissions** — uses Carbon `RegisterEventHotKey` for global hotkeys and local NSEvent monitors from overlay windows (only active when overlay is showing)
- **OverlayWindow** is a custom NSWindow subclass that intercepts keyDown for Escape, arrow keys, backspace, and text input
- **Focus guard** runs a 0.5s timer + listens for app resign/become active notifications to reclaim focus
- **Window level is `.screenSaver`** with `.canJoinAllSpaces, .stationary` behavior
- **`isOpaque` must be `false`** when opacity < 1.0 — otherwise macOS ignores `withAlphaComponent`
- **suppressFocusReassert** flag on OverlayWindow prevents race conditions during fade-out animation
- **Screen changes** (displays added/removed) trigger immediate window recreation without animation, preserving current opacity
- **Password mode**: hotkey only activates (never deactivates), menu click also cannot deactivate
- **KeychainHelper** is misnamed — it uses UserDefaults, not the keychain

## Gotchas

- `setFrame(screen.frame, display: true)` must be called explicitly after window init — contentRect doesn't map correctly to external displays in global coordinates
- Carbon hotkey callback uses `Unmanaged<HotkeyManager>.fromOpaque()` — must unregister before dealloc or it references dangling memory
- Local event monitors are not auto-cleaned by NSEvent — manually tracked and removed in `stopLocalKeyMonitor()`
- PasswordMatcher does "smart re-match": if a wrong character matches the first password character, it advances to position 1 instead of fully resetting
