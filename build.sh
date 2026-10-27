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
codesign --force -s - "$APP"
if [ "$1" = "--install" ]; then
	DEST=/Applications/ReSpace
	[ -d "$DEST" ] || DEST=/Applications
	pkill -x ReDesk || true
	rm -rf "$DEST/ReDesk.app"
	cp -R "$APP" "$DEST/"
	open "$DEST/ReDesk.app"
fi
