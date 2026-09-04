#!/bin/bash
# Re-record simulation goldens. Only run this when a change is MEANT to alter
# the animation, and look at `isoharness sheet` first.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$DIR/build.sh" >/dev/null
for movement in walkers wave ripple; do
    "$DIR/.build/isoharness" hash --seed 7 --frames 300 --movement "$movement" \
        | grep DIGEST > "$DIR/goldens/$movement-seed7.digest"
    echo "$movement: $(cat "$DIR/goldens/$movement-seed7.digest")"
done
