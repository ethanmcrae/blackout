# Blackout

A macOS menu bar app that covers all screens with a black overlay. Useful for turning your monitor into a dark surface without sleeping or turning it off.

## Features

- **Full-screen black overlay** across all connected displays
- **Two unlock methods:**
  - **Password** (recommended) — type a secret password character-by-character to dismiss
  - **Hotkey** — use a keyboard shortcut (e.g. Cmd+Shift+B) to toggle
- **Password feedback** — subtle asterisk progress/error indicators on the primary display (invisible to observers at a distance)
- **Backspace support** — correct typos while typing your password
- **Triple-Escape dismiss** — emergency dismiss via triple-press Escape (on by default, togglable from the menu bar)
- **Cursor hidden** while the overlay is active
- **Focus guard** — the overlay stays on top and reclaims focus if another app tries to steal it
- **Launch at Login** support
- **Sleep prevention** — keeps the display awake while blacked out
- **Guided setup** — first launch walks you through choosing an unlock method and practicing

## Install via AI Agent

Copy the following prompt into your AI coding agent (Claude Code, Cursor, etc.):

```
Install Blackout — a macOS menu bar app that blacks out all screens.

1. Clone: git clone https://github.com/ethanmcrae/blackout.git ~/Downloads/blackout
2. Install: cp -r ~/Downloads/blackout/Blackout.app /Applications/Blackout.app
3. Clean up: rm -rf ~/Downloads/blackout
4. Launch: open /Applications/Blackout.app

On first launch it will appear in the menu bar and walk you through setup.
```

## Manual Install

```bash
git clone https://github.com/ethanmcrae/blackout.git ~/Downloads/blackout
cp -r ~/Downloads/blackout/Blackout.app /Applications/
rm -rf ~/Downloads/blackout
open /Applications/Blackout.app
```

## Screen Saver

Blackout also includes an animated isometric grid screen saver.

### Install Screen Saver

```bash
git clone https://github.com/ethanmcrae/blackout.git ~/Downloads/blackout
cd ~/Downloads/blackout/BlackoutSaver
bash build.sh
cp -r BlackoutSaver.saver ~/Library/Screen\ Savers/
```

Then open **System Settings → Screen Saver** and select **BlackoutSaver**.

### Build Screen Saver from Source

```bash
cd blackout/BlackoutSaver
bash build.sh
```

## Build from Source

If you want to modify the app, you can rebuild it. Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
cd blackout
mkdir -p Blackout.app/Contents/{MacOS,Resources}
cp Blackout/Info.plist Blackout.app/Contents/Info.plist
cp Blackout/AppIcon.icns Blackout.app/Contents/Resources/
swiftc -o Blackout.app/Contents/MacOS/Blackout \
  Blackout/main.swift Blackout/AppDelegate.swift Blackout/OverlayManager.swift \
  Blackout/HotkeyManager.swift Blackout/SetupWindowController.swift \
  Blackout/SleepPrevention.swift Blackout/PasswordMatcher.swift \
  Shared/AnimationModule.swift Shared/IsometricModule.swift \
  -framework Cocoa -framework Carbon -framework ServiceManagement
```

## Usage

- **Menu bar icon** — click the moon icon to activate/deactivate or change settings
- **Password mode** — the overlay goes black; type your password to dismiss (asterisks show progress briefly)
- **Hotkey mode** — press your configured shortcut to toggle the overlay
- **Triple-Escape dismiss** — triple-press Escape to dismiss (toggle on/off from the menu bar)
- **Change Unlock Method** — available from the menu bar dropdown
- **Launch at Login** — togglable from the menu bar
