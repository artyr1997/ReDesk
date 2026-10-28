#!/bin/sh
# Builds ReDesk.app into build/ and, with --install, puts it next to the other Re apps.
set -e
cd "$(dirname "$0")"
APP=build/ReDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/ReDesk" Sources/main.swift
cp Info.plist "$APP/Contents/"
cp Resources/* "$APP/Contents/Resources/"
cp -R wallpapers "$APP/Contents/Resources/"
# ad-hoc, but known by its identifier rather than by this build's hash, so macOS keeps
# the Accessibility and audio permissions from one build to the next
codesign --force -s - -r='designated => identifier "com.artursavytskyi.redesk"' "$APP"
if [ "$1" = "--install" ]; then
	DEST=/Applications/ReSpace
	[ -d "$DEST" ] || DEST=/Applications
	pkill -x ReDesk || true
	rm -rf "$DEST/ReDesk.app"
	cp -R "$APP" "$DEST/"
	open "$DEST/ReDesk.app"
fi
