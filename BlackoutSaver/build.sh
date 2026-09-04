#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$DIR/../Shared"
BUNDLE="$DIR/Blackout.saver"

# Clean
rm -rf "$BUNDLE"

# Create bundle structure
mkdir -p "$BUNDLE/Contents/MacOS"

# Copy Info.plist
cp "$DIR/Info.plist" "$BUNDLE/Contents/Info.plist"

# Compile as loadable bundle using shared animation modules
swiftc -O \
    -module-name BlackoutSaver \
    -parse-as-library \
    -emit-library \
    -o "$BUNDLE/Contents/MacOS/BlackoutSaver" \
    "$DIR/BlackoutSaverView.swift" \
    "$SHARED/AnimationModule.swift" \
    "$SHARED/IsometricModule.swift" \
    "$SHARED/IsometricSimulation.swift" \
    "$SHARED/IsometricRenderer.swift" \
    "$SHARED/IsometricMetalRenderer.swift" \
    -framework ScreenSaver \
    -framework Cocoa \
    -framework Metal \
    -framework QuartzCore

echo "Built: $BUNDLE"
echo ""
echo "To install:"
echo "  cp -r '$BUNDLE' ~/Library/Screen\\ Savers/"
echo ""
echo "Then open System Settings > Screen Saver and select 'Blackout'"
