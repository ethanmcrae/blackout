#!/bin/bash
# Build the isometric render verification harness.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/.."
OUT="$DIR/.build"
mkdir -p "$OUT"
swiftc -O \
    -o "$OUT/isoharness" \
    "$DIR/main.swift" \
    "$ROOT/Shared/AnimationModule.swift" \
    "$ROOT/Shared/IsometricModule.swift" \
    "$ROOT/Shared/IsometricSimulation.swift" \
    "$ROOT/Shared/IsometricRenderer.swift" \
    "$ROOT/Shared/IsometricMetalRenderer.swift" \
    -framework Cocoa -framework Metal -framework QuartzCore -framework ImageIO
echo "Built: $OUT/isoharness"
