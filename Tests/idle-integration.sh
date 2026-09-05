#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/build/IdleVictim.app"
mkdir -p "$FIXTURE/Contents/MacOS"
swiftc -parse-as-library -O -target "$(uname -m)-apple-macos13.0" \
  "$ROOT/Tests/IdleVictim.swift" -framework Cocoa -o "$FIXTURE/Contents/MacOS/IdleVictim"
cat > "$FIXTURE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IdleVictim</string>
<key>CFBundleIdentifier</key><string>com.quitonclose.test.idlevictim</string>
<key>CFBundleName</key><string>IdleVictim</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
"$ROOT/build/QuitOnClose.app/Contents/MacOS/QuitOnClose" --idletest "$FIXTURE"
