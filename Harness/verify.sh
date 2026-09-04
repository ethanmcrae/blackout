#!/bin/bash
# Full verification for the isometric animation. Run this after ANY change to
# Shared/, and before pushing. Exits non-zero if anything fails.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/.."
OUT="${TMPDIR:-/tmp}/blackout-verify"
mkdir -p "$OUT"
fail=0
pass=0

step() { printf "%-52s" "$1"; }
ok()   { echo "PASS"; pass=$((pass+1)); }
bad()  { echo "FAIL  ($1)"; fail=$((fail+1)); }

echo "=== build ==="
step "app (optimised)"
if swiftc -O -o "$OUT/Blackout" \
    "$ROOT"/Blackout/main.swift "$ROOT"/Blackout/AppDelegate.swift \
    "$ROOT"/Blackout/OverlayManager.swift "$ROOT"/Blackout/HotkeyManager.swift \
    "$ROOT"/Blackout/SetupWindowController.swift "$ROOT"/Blackout/SleepPrevention.swift \
    "$ROOT"/Blackout/PasswordMatcher.swift \
    "$ROOT"/Shared/*.swift \
    -framework Cocoa -framework Carbon -framework ServiceManagement \
    -framework Metal -framework QuartzCore >"$OUT/app.log" 2>&1; then ok; else bad "see $OUT/app.log"; fi

step "screen saver bundle"
if bash "$ROOT/BlackoutSaver/build.sh" >"$OUT/saver.log" 2>&1; then ok; else bad "see $OUT/saver.log"; fi

step "harness"
if bash "$DIR/build.sh" >"$OUT/harness.log" 2>&1; then ok; else bad "see $OUT/harness.log"; fi

HARNESS="$DIR/.build/isoharness"

echo
echo "=== renderer agreement (CPU reference vs GPU) ==="
for movement in walkers wave ripple; do
  for scale in 1 2; do
    for mode in dark light; do
      flag=""; [ "$mode" = light ] && flag="--light"
      step "$movement  scale=${scale}x  $mode"
      if "$HARNESS" compare --frames 60 --movement "$movement" --scale "$scale" $flag \
           --out "$OUT/$movement-$scale-$mode" >"$OUT/$movement-$scale-$mode.log" 2>&1; then ok
      else bad "see $OUT/$movement-$scale-$mode.log"; fi
    done
  done
done

echo
echo "=== accent colours ==="
for color in blue pink green white; do
  step "accent $color"
  if "$HARNESS" compare --frames 40 --color "$color" --out "$OUT/color-$color" \
       >"$OUT/color-$color.log" 2>&1; then ok; else bad "see $OUT/color-$color.log"; fi
done

echo
echo "=== the harness itself still detects a dead render ==="
step "all-black render must FAIL"
"$HARNESS" compare --frames 3 --size 20x20 --out "$OUT/black" >"$OUT/black.log" 2>&1
if [ $? -ne 0 ]; then ok; else bad "an empty render was accepted"; fi

echo
echo "=== screen saver bundle loads ==="
step "compile smoke test"
if swiftc -O -o "$OUT/saver-smoke" "$DIR/saver-smoke/main.swift" \
     -framework Cocoa -framework ScreenSaver >"$OUT/smoke-build.log" 2>&1; then ok
else bad "see $OUT/smoke-build.log"; fi
step "load and tick 60 frames"
if "$OUT/saver-smoke" "$ROOT/BlackoutSaver/Blackout.saver" >"$OUT/smoke.log" 2>&1; then ok
else bad "see $OUT/smoke.log"; fi

echo
echo "------------------------------------------------------"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "Not covered here: the live on-screen path. Run that by hand:"
echo "  $HARNESS window --movement ripple --seconds 8"
