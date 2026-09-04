#!/bin/bash
# Re-record simulation goldens. Only run this when a change is MEANT to alter
# the animation, and look at `isoharness sheet` first.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$DIR/build.sh" >/dev/null
# 900 frames, not 300: ripple interference only occurs once two rings
# have expanded far enough to cross, which takes longer than 300 frames.
for movement in walkers wave ripple terrain noise rain flow wavefield; do
    "$DIR/.build/isoharness" hash --seed 7 --frames 900 --movement "$movement" \
        | grep DIGEST > "$DIR/goldens/$movement-seed7.digest"
    echo "$movement: $(cat "$DIR/goldens/$movement-seed7.digest")"
done
