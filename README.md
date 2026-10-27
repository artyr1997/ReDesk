# ReDesk

The Re apps as words in the corners of the desktop: FILE (ReFile) and SURF (ReSurf) at the top, HEAR (ReSound) and NOTE (ReNote) at the bottom. A click opens the app; a right click can set ReDesk to open at login, or quit it.

Around them:
- **Left edge**: the wallpapers in `wallpapers/`, as dots; the one on the desktop is a diamond. A click sets one, **⌃⌥↑ / ⌃⌥↓** step through them from anywhere.
- **Top**: how much of the day has gone, midnight to midnight, with a mark at noon.
- **Right edge**: the battery, filling from the bottom.

Empty parts are white at 25%, filled ones (and the chosen wallpaper) at 50%. A right click on a bar shows the time or the battery level.

The pieces sit just above the desktop icons and below every window, in the apps' side-button lettering (Noto Sans JP, upright, one letter every 32pt).

```sh
./build.sh            # build/ReDesk.app
```

Then copy `build/ReDesk.app` to `/Applications/ReSpace` (next to the other Re apps) and open it.
