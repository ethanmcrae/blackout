# Blackout

A macOS menu bar app that covers all screens with a black overlay. Useful for turning your monitor into a dark surface without sleeping or turning it off.

## Features

- **Full-screen black overlay** across all connected displays
- **Two unlock methods:**
  - **Password** (recommended) — type a secret password character-by-character to dismiss
  - **Hotkey** — use a keyboard shortcut (e.g. Cmd+Shift+B) to toggle
- **Cursor hidden** while the overlay is active
- **Subtle visual feedback** when typing a password (invisible to observers, visible to you in the dark)
- **Triple-Escape** emergency dismiss always works regardless of unlock method
- **Launch at Login** support
- **Sleep prevention** — keeps the display awake while blacked out

## Install via AI Agent

Copy the following into your AI coding agent (Claude Code, Cursor, etc.):

```
Clone and build Blackout — a macOS menu bar app that blacks out all screens.

1. Clone: git clone https://github.com/ethanmcrae/blackout.git ~/blackout
2. Build:
   cd ~/blackout
   swiftc -o Blackout.app/Contents/MacOS/Blackout \
     -target arm64-apple-macos13 \
     -sdk $(xcrun --sdk macosx --show-sdk-path) \
     -framework Cocoa -framework Carbon -framework Security -framework ServiceManagement \
     Blackout/main.swift Blackout/AppDelegate.swift Blackout/OverlayManager.swift \
     Blackout/HotkeyManager.swift Blackout/SetupWindowController.swift \
     Blackout/SleepPrevention.swift Blackout/PasswordMatcher.swift
3. Copy to Applications: cp -r Blackout.app /Applications/Blackout.app
4. Launch it: open /Applications/Blackout.app

On first launch it will appear in the menu bar and walk you through setup.
```

## Manual Build

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/ethanmcrae/blackout.git
cd blackout
swiftc -o Blackout.app/Contents/MacOS/Blackout \
  -target arm64-apple-macos13 \
  -sdk $(xcrun --sdk macosx --show-sdk-path) \
  -framework Cocoa -framework Carbon -framework Security -framework ServiceManagement \
  Blackout/main.swift Blackout/AppDelegate.swift Blackout/OverlayManager.swift \
  Blackout/HotkeyManager.swift Blackout/SetupWindowController.swift \
  Blackout/SleepPrevention.swift Blackout/PasswordMatcher.swift
cp -r Blackout.app /Applications/
open /Applications/Blackout.app
```

## Usage

- **Menu bar icon** — click the moon icon to activate/deactivate or change settings
- **Password mode** — the overlay goes black; type your password to dismiss
- **Hotkey mode** — press your configured shortcut to toggle the overlay
- **Emergency dismiss** — triple-press Escape (always works)
- **Change Unlock Method** — available from the menu bar dropdown
