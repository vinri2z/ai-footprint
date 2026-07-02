#!/usr/bin/env bash
# build-app.sh — compile the Swift menu-bar app and assemble "AI Footprint.app".
#
# Produces desktop/build/AI Footprint.app (menu-bar only, LSUIElement) with the
# bash/python footprint pipeline bundled under Contents/Resources. The runtime deps
# (python3, node, jq, git) are NOT bundled — they come from the Homebrew cask's
# `depends_on formula:` list.
#
# Usage: bash desktop/build-app.sh [--zip]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/desktop/AiFootprintMenuBar/main.swift"
BUILD="${REPO_ROOT}/desktop/build"
APP="${BUILD}/AI Footprint.app"
EXE_NAME="AiFootprintMenuBar"
BUNDLE_ID="com.vinri2z.ai-footprint"

VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "${REPO_ROOT}/.claude-plugin/plugin.json")"

echo "Building AI Footprint.app v${VERSION}"

# 1. Clean + compile
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

ARCH="$(uname -m)"  # arm64 or x86_64
swiftc -O \
  -target "${ARCH}-apple-macos13.0" \
  -o "${APP}/Contents/MacOS/${EXE_NAME}" \
  "$SRC"

# 2. Info.plist (LSUIElement = menu-bar only, no Dock icon)
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI Footprint</string>
  <key>CFBundleDisplayName</key><string>AI Footprint</string>
  <key>CFBundleExecutable</key><string>${EXE_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT — github.com/vinri2z/ai-footprint</string>
</dict>
</plist>
PLIST

# 3. Bundle the footprint pipeline (scripts/ + data/ as siblings so
#    scripts/../data/factors.json resolves inside the bundle).
cp -R "${REPO_ROOT}/scripts" "${APP}/Contents/Resources/scripts"
cp -R "${REPO_ROOT}/data"    "${APP}/Contents/Resources/data"

# 4. Ad-hoc codesign — required for SMAppService (launch-at-login) and for
#    Gatekeeper to run the unsigned bundle locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "warning: codesign failed (app will still run, but launch-at-login may not)"

echo "Built: $APP"

# 5. Optional zip for cask distribution
if [[ "${1:-}" == "--zip" ]]; then
  ZIP="${BUILD}/AI-Footprint-${VERSION}.zip"
  rm -f "$ZIP"
  ( cd "$BUILD" && ditto -c -k --keepParent "AI Footprint.app" "$ZIP" )
  echo "Zipped: $ZIP"
fi
