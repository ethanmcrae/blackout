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
  Shared/AnimationModule.swift Shared/IsometricModule.swift \
  Shared/IsometricSimulation.swift Shared/IsometricRenderer.swift \
  Shared/IsometricMetalRenderer.swift \
  -framework Cocoa -framework Carbon -framework ServiceManagement \
  -framework Metal -framework QuartzCore
```

When adding new `.swift` files, add them to the `swiftc` command above AND update the README build section.

## Deploy

```bash
rm -rf /Applications/Blackout.app
cp -r ~/Documents/Tools/black-screen/Blackout.app /Applications/Blackout.app
```

## After Code Changes

Always: build → commit → push → copy to /Applications (replacing the existing app).

## Verifying Animation Changes

IMPORTANT: never change rendering or simulation code without running `Harness/`.
The animation cannot be checked by reading a diff, and a build that compiles can
still be visually broken.

```bash
bash Harness/build.sh

# CPU vs GPU pixel diff -- both renderers get the IDENTICAL frame data, so any
# disagreement is a rendering bug and nothing else. Exits non-zero on mismatch.
./Harness/.build/isoharness compare --frames 120 --movement walkers
./Harness/.build/isoharness compare --frames 120 --movement wave
./Harness/.build/isoharness compare --frames 120 --movement ripple

# Contact sheet across time -- open the PNG and confirm the animation evolves.
./Harness/.build/isoharness sheet --frames 600 --every 60 --movement walkers

# Real window, real CAMetalLayer, screenshotted. The compare path does NOT
# cover the on-screen path (backing layer, drawableSize, contentsScale).
./Harness/.build/isoharness window --movement ripple --seconds 8

# CPU cost per frame, both renderers.
./Harness/.build/isoharness bench --frames 150
```

`bench` draws into one long-lived bitmap context, matching what the view does
when it draws into the window's backing store. Allocating a fresh context per
frame charges the background fill for faulting in ~30MB of cold pages and
roughly triples the Core Graphics figure -- an early version of this tool did
that and overstated the speedup by about 4x. Measure a renderer against a warm
destination, or the number is about the allocator, not the renderer.

Steady-state cost while the overlay is up, as a share of one CPU core:

| Mode | Before | After | GPU added |
| --- | --- | --- | --- |
| Walkers | 3.5-6.5% | 1.1-1.3% | 1.1-2.5% |
| Ripple | 3.9-6.0% | 1.1-1.5% | 0.7-1.7% |
| Wave | 3.3-6.2% | 1.9-5.2% | 0.7-1.7% |

Wave gains least. Its Core Graphics path already batched strokes into five
paths, and `IsometricSimulation.fill` costs 0.4-0.8 ms per frame there because
it does two dictionary lookups per lit edge. Moving the simulation to
index-based storage is the obvious next win if that mode matters.

Useful flags: `--size WxH`, `--scale`, `--color`, `--light`, `--crop x,y,w,h`,
`--zoom N` (nearest-neighbour magnification, for looking at individual pixels),
`--out DIR`.

`compare` reports `VERDICT: MATCH` when the only differences are anti-aliasing.
Healthy numbers are max channel delta under ~15/255, zero pixels disagreeing by
more than 32/255, and an ink ratio within 0.999-1.001. A structural bug (flipped
axis, wrong scale, dropped segments) shows up immediately as pixels over 128.

Do NOT verify by activating the real overlay. It sets `NSApp.presentationOptions`
to disable Cmd+Tab, Force Quit and session termination, and the user's install
uses password unlock with triple-Escape dismiss turned off -- activating it
unattended can lock the machine.

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
| `Shared/IsometricSimulation.swift` | Pure simulation: grid generation, walkers/wave/ripple, fading. No AppKit, no drawing. Emits an `IsometricFrame` of lit segments |
| `Shared/IsometricRenderer.swift` | `IsometricCGRenderer` — Core Graphics reference renderer, and the shared `IsometricRenderParams` |
| `Shared/IsometricMetalRenderer.swift` | GPU renderer. One instanced draw call per frame; shader compiled at runtime from a Swift string |
| `Shared/IsometricModule.swift` | `NSView` host: owns the simulation, drives the timer, renders through Metal (or Core Graphics if Metal is unavailable) |
| `Harness/main.swift` | Verification tool — see "Verifying Animation Changes" |
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

## Rendering Notes

- **Simulation and rendering are separate.** `IsometricSimulation` decides what is
  lit; renderers only draw. Both renderers consume the same `IsometricFrame`,
  which is what makes the CPU/GPU pixel diff meaningful.
- **The Metal shader is compiled at runtime** with `makeLibrary(source:)`. That
  keeps the build to plain `swiftc` — there is no `.metal` file and no metallib
  step, and it does not need a full Xcode install.
- **Lines are quads, not strokes.** Each lit segment is one instance of a
  4-vertex triangle strip; the fragment shader computes analytic coverage from
  the distance to the centre line, giving anti-aliasing without MSAA.
- **The anti-aliasing ramp is a fixed half pixel.** Widening it by the line's
  angle looks principled and is wrong — it overshoots Core Graphics by ~10%.
  The harness catches this as an ink ratio around 1.1.
- **Colours are built in an explicit sRGB colour space.** `CGColor(red:green:blue:alpha:)`
  carries an unspecified space, so Core Graphics converts it per stroke and
  shifts the accent hue in dim pixels. That was a real ~13% ink discrepancy.
- **Every segment is the accent colour at `alpha = lit`** over a black or white
  ground. For a single segment that is algebraically identical to the old opaque
  `accent * lit` formula, and it blends correctly where segments cross.

## Gotchas

- `setFrame(screen.frame, display: true)` must be called explicitly after window init — contentRect doesn't map correctly to external displays in global coordinates
- Carbon hotkey callback uses `Unmanaged<HotkeyManager>.fromOpaque()` — must unregister before dealloc or it references dangling memory
- Local event monitors are not auto-cleaned by NSEvent — manually tracked and removed in `stopLocalKeyMonitor()`
- PasswordMatcher does "smart re-match": if a wrong character matches the first password character, it advances to position 1 instead of fully resetting
- The FPS counter is a `CATextLayer` and must be attached *after* `wantsLayer` is set, or it silently never appears
- `Blackout.app` is ad-hoc signed. After rebuilding the binary, re-sign it with `codesign --force --sign - Blackout.app`, or macOS may refuse to launch it
