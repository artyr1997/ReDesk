#!/bin/sh
# Builds ReDesk.app into build/ and, with --install, puts it next to the other Re apps.
set -e
cd "$(dirname "$0")"
APP=build/ReDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/ReDesk" Sources/*.swift
cp Info.plist "$APP/Contents/"
cp Resources/* "$APP/Contents/Resources/"
cp -R wallpapers "$APP/Contents/Resources/"
# ad-hoc, but known by its identifier rather than by this build's hash, so macOS keeps
# the Accessibility and audio permissions from one build to the next
# Signed as well as the keychain allows: with a Developer ID Application certificate for others' Macs (the
# hardened runtime and a timestamp, as notarizing wants); else with an Apple Development one (this Mac); else ad
# hoc. The team is in the requirement, so the permissions given (Accessibility and the like) outlive rebuilds.
IDENTITIES=$(security find-identity -v -p codesigning)
IDENTITY=$(echo "$IDENTITIES" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
RUNTIME="--options runtime --timestamp --entitlements ReDesk.entitlements"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(echo "$IDENTITIES" | awk -F'"' '/Apple Development/ {print $2; exit}')
  RUNTIME="--timestamp=none"
fi
if [ -n "$IDENTITY" ]; then
  TEAM=$(security find-certificate -c "$IDENTITY" -p | openssl x509 -noout -subject -nameopt multiline | awk -F'= ' '/organizationalUnitName/ {print $2; exit}')
  codesign --force $RUNTIME -s "$IDENTITY" \
    -r="designated => identifier \"com.artursavytskyi.redesk\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$APP"
else
  codesign --force -s - -r='designated => identifier "com.artursavytskyi.redesk"' "$APP"
fi
if [ "$1" = "--install" ]; then
	DEST=/Applications/ReSpace
	[ -d "$DEST" ] || DEST=/Applications
	pkill -x ReDesk || true
	rm -rf "$DEST/ReDesk.app"
	cp -R "$APP" "$DEST/"
	open "$DEST/ReDesk.app"
fi
