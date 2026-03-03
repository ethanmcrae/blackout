# CLAUDE.md — Blackout

## Build

Uses `swiftc` directly (not `xcodebuild` or `swift build`). Requires Xcode Command Line Tools.

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

## Deploy

After building, replace the installed app:

```bash
rm -rf /Applications/Blackout.app
cp -r ~/Documents/Tools/black-screen/Blackout.app /Applications/Blackout.app
```

## After Code Changes

Always: build, commit, push, then copy to /Applications (replacing the existing app).

## Project Structure

- `Blackout/` — all Swift source files
- `Blackout.app/` — local build output (committed to repo as pre-built distribution)
- All source is in a single flat directory; no nested modules
