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
      # A wave sweep needs long enough to cross onto the screen.
      frames=60; [ "$movement" = wave ] && frames=140
      step "$movement  scale=${scale}x  $mode"
      if "$HARNESS" compare --frames "$frames" --movement "$movement" --scale "$scale" $flag \
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
echo "=== simulation output (renderer comparison is blind to this) ==="
for movement in walkers wave ripple; do
  step "$movement matches its golden digest"
  golden="$DIR/goldens/$movement-seed7.digest"
  if [ ! -f "$golden" ]; then bad "no golden recorded"; continue; fi
  actual=$("$HARNESS" hash --seed 7 --frames 300 --movement "$movement" 2>/dev/null | grep DIGEST)
  if [ "$actual" = "$(cat "$golden")" ]; then ok
  else bad "got $actual, expected $(cat "$golden")"; fi
done

step "the same seed is reproducible across processes"
d1=$("$HARNESS" hash --seed 21 --frames 120 --movement walkers 2>/dev/null | grep DIGEST)
d2=$("$HARNESS" hash --seed 21 --frames 120 --movement walkers 2>/dev/null | grep DIGEST)
if [ "$d1" = "$d2" ]; then ok; else bad "non-deterministic: $d1 vs $d2"; fi

step "different seeds produce different runs"
d3=$("$HARNESS" hash --seed 22 --frames 120 --movement walkers 2>/dev/null | grep DIGEST)
if [ "$d1" != "$d3" ]; then ok; else bad "seed is being ignored"; fi

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
