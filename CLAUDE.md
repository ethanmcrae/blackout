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
swiftc -O -o Blackout.app/Contents/MacOS/Blackout \
  Blackout/*.swift Shared/*.swift \
  -framework Cocoa -framework Carbon -framework ServiceManagement \
  -framework Metal -framework QuartzCore
```

The build globs `Blackout/*.swift` and `Shared/*.swift`, so a new source file needs no build change. Run `bash Harness/verify.sh` after any change under `Shared/` or `Blackout/`.

## Deploy

```bash
rm -rf /Applications/Blackout.app
cp -r ~/Documents/Tools/black-screen/Blackout.app /Applications/Blackout.app
```

## After Code Changes

Always: build → commit → push → copy to /Applications (replacing the existing app).

## Verifying Animation Changes

IMPORTANT: run `bash Harness/verify.sh` after ANY change under `Shared/`, and
before pushing. It builds all three targets and runs 29 checks. An animation
cannot be checked by reading a diff, and a build that compiles can still be
visually dead.

```bash
bash Harness/verify.sh          # the whole suite, exits non-zero on failure
```

What it covers, and why each part exists:

| Check | Catches |
|---|---|
| CPU vs GPU pixel diff, per movement x scale x light/dark x accent | any rendering bug |
| Simulation golden digests | a simulation regression, which the pixel diff is blind to |
| Same seed reproduces across processes | non-determinism creeping back in |
| An all-black render must FAIL | the harness itself going blind |
| Core Graphics fallback renders | the path Macs without a GPU use |
| Screen saver bundle loads and ticks | a `.saver` that will not open |

The single most important thing to understand: **`compare` feeds the identical
frame data to both renderers**, so it proves they agree, and proves nothing
about whether the simulation is right. A broken simulation makes both renderers
agree on wrong output. That is what the golden digests are for.

Individual commands:

```bash
./Harness/.build/isoharness compare  --frames 120 --movement walkers
./Harness/.build/isoharness hash     --seed 7 --frames 300 --movement wave
./Harness/.build/isoharness sheet    --frames 600 --every 60 --movement walkers
./Harness/.build/isoharness window   --movement ripple --seconds 8
./Harness/.build/isoharness fallback --frames 240
./Harness/.build/isoharness bench    --frames 150
./Harness/.build/isoharness profile
```

Flags: `--size WxH`, `--scale`, `--color`, `--light`, `--seed N`,
`--crop x,y,w,h`, `--zoom N` (nearest-neighbour, for looking at real pixels),
`--out DIR`.

`window` is the only check of the live on-screen path (backing layer,
drawableSize, contentsScale, drawable presentation) and needs a real display,
so verify.sh prints it as a manual step rather than running it.

**When a golden digest changes**, that is the tool working. Confirm the change
was intended, LOOK at `isoharness sheet` output, then re-record with
`bash Harness/record-goldens.sh`. Never re-record to make a red suite go green.

**Steady-state cost** while the overlay is up, share of one CPU core, versus the
original Core Graphics renderer:

| Mode | Before | After | GPU added |
|---|---|---|---|
| walkers 16" / 34" | 5.6% / 8.3% | 1.58% / 1.60% | 0.96% / 2.32% |
| wave 16" / 34" | 6.3% / 11.5% | 1.46% / 1.95% | 0.78% / 1.92% |
| ripple 16" / 34" | 5.6% / 9.0% | 1.32% / 1.76% | 0.78% / 1.87% |

Do NOT verify by activating the real overlay. It sets `NSApp.presentationOptions`
to disable Cmd+Tab, Force Quit and session termination, and the user's install
uses password unlock with triple-Escape dismiss off -- activating it unattended
can lock the machine.

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
| `Shared/IsometricSimulation.swift` | Pure simulation: grid generation, walkers/wave/ripple, fading. No AppKit, no drawing. Emits an `IsometricFrame` of lit segments. State is index-parallel arrays keyed by position in the canonically sorted `activeEdgeArray` |
| `Harness/verify.sh` | The 29-check suite. Run it after any `Shared/` change |
| `Harness/goldens/` | Simulation output digests. See "Verifying Animation Changes" |
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

- **Randomness is seeded and container order is canonical.** Swift seeds its
  hasher per process, and that order used to leak into the output through edge
  indices, adjacency order and emit order. Everything feeding the animation is
  sorted. `AnimationConfig.seed` pins the generator; unseeded it still varies
  per launch.
- **Simulation state is index-parallel arrays**, not dictionaries keyed on
  `GridEdge`. The old form hashed a 32-byte key about five times per lit edge
  per frame. Anything added to the per-frame path should follow that pattern.
- **Effects live in the frame data, not in one renderer.** The vignette and the
  walker trail gradient are computed in the simulation so both renderers
  produce them identically. An effect implemented only in the shader would make
  the CPU and GPU renderers diverge and take the whole verification suite red.
  The warm core is the exception that genuinely must exist in both, so the
  formula is written out on each side with a comment pointing at the other.

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
