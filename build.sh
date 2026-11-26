#!/bin/sh
# Builds ReDesk.app into build/ and, with --install, puts it next to the other Re apps.
set -e
cd "$(dirname "$0")"
APP=build/ReDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# for every Mac from macOS 13 on, Apple silicon and Intel both
for ARCH in arm64 x86_64; do
  swiftc -O -module-name ReDesk -target $ARCH-apple-macos13.0 -o "build/ReDesk-$ARCH" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/ReDesk" build/ReDesk-arm64 build/ReDesk-x86_64
rm -f build/ReDesk-arm64 build/ReDesk-x86_64
cp Info.plist "$APP/Contents/"
cp -R Resources/* "$APP/Contents/Resources/"
cp -R wallpapers "$APP/Contents/Resources/"
# ad-hoc, but known by its identifier rather than by this build's hash, so macOS keeps
# the Accessibility and audio permissions from one build to the next
# Signed as well as the keychain allows: with a Developer ID Application certificate for others' Macs (the
# hardened runtime and a timestamp, as notarizing wants); else with an Apple Development one (this Mac); else ad
# hoc. The team is in the requirement, so the permissions given (Accessibility and the like) outlive rebuilds.
# the symbols only a debugger reads left out, so the download stays small
strip -x "$APP/Contents/MacOS/ReDesk"
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
	# where it is already: straight in /Applications, or in /Applications/ReSpace; new: /Applications
	DEST=/Applications
	[ ! -d /Applications/ReDesk.app ] && [ -d /Applications/ReSpace/ReDesk.app ] && DEST=/Applications/ReSpace
	pkill -x ReDesk || true
	rm -rf "$DEST/ReDesk.app"
	cp -R "$APP" "$DEST/"
	open "$DEST/ReDesk.app"
fi
