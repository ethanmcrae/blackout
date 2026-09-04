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
swiftc -O -o Blackout.app/Contents/MacOS/Blackout \
  Blackout/*.swift Shared/*.swift \
  -framework Cocoa -framework Carbon -framework ServiceManagement \
  -framework Metal -framework QuartzCore
```

## Rendering

The isometric animation runs on the GPU through Metal. The simulation that
decides which grid edges are lit is separate from the code that draws them, and
a Core Graphics renderer is kept as a reference so GPU output can be diffed
against CPU output pixel for pixel. On a Mac without Metal the app falls back to
the Core Graphics path automatically.

While the overlay is up, the animation's CPU cost drops from roughly 5.6-11.5%
of one core to 1.3-2.0%, in exchange for 0.8-2.3% of the GPU. The animation also
stops entirely when the display sleeps or the window is fully occluded, which it
did not before.

### Verifying a change to the animation

```bash
bash Harness/verify.sh                                    # the whole suite
./Harness/.build/isoharness window --movement ripple --seconds 8   # live path
```

`bash Harness/verify.sh` runs everything: 29 checks covering renderer
agreement, simulation golden digests, determinism, the Core Graphics fallback,
and whether the screen saver bundle loads. Run it before pushing.

## Usage

- **Menu bar icon** — click the moon icon to activate/deactivate or change settings
- **Password mode** — the overlay goes black; type your password to dismiss (asterisks show progress briefly)
- **Hotkey mode** — press your configured shortcut to toggle the overlay
- **Triple-Escape dismiss** — triple-press Escape to dismiss (toggle on/off from the menu bar)
- **Change Unlock Method** — available from the menu bar dropdown
- **Launch at Login** — togglable from the menu bar
