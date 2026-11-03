# ReDesk

The Re apps as words in the corners of the desktop: FILE (ReFile) and SURF (ReSurf) at the top, HEAR (ReSound) and NOTE (ReNote) at the bottom. A click opens the app; a right click can set ReDesk to open at login, or quit it.

Around them:
- **Left edge**: the wallpapers in `wallpapers/Light` or `wallpapers/Dark`, as the Mac's appearance is (pictures, and videos: mp4 / mov), as dots; when the appearance changes (⌘⇧T, say) the desktop takes the other folder's wallpaper, the one last chosen there or its first. The folders stay out of git (too big); the one on the desktop is a diamond. A click sets one, **⌘⇧↑ / ⌘⇧↓** step through them (in the Re apps, see Keys). The old wallpaper fades into the new one (once a new video has its first frame).
- Videos play muted and looping under the desktop icons on every screen, and pause while the displays sleep. A still of the first frame (kept in `~/Library/Application Support/ReDesk`) is set as the macOS wallpaper underneath, so the choice survives a restart.
- **Top**: how much of the day has gone, midnight to midnight, with a mark at noon.
- **Right edge**: the battery, filling from the bottom.
- **Bottom**: while sound plays, three soft lines drift like a wave, as high as the sound is loud; in silence they settle flat and away. The loudness comes from a Core Audio tap, so macOS asks once for permission to capture audio (nothing is recorded or kept).

**Tiling** (right click › Tile Windows, or **⌃⌥T**): the windows of the Re apps (ReFile, ReSurf, ReSound, ReNote, ReBook) share the middle of the desk, between the side columns, 40pt under the day line and over the wave, 10pt apart. One window fills it; with more, the newest is the main one and the arrangement places the rest:
  - **Main and Stack**: the main one on the left half, the others one above another on the right
  - **Main on Top**: the main one across the top 60%, the others side by side under it
  - **Main in the Middle**: the main one in the middle half, the others shared out to the left and the right
  - **Columns** / **Rows**: all equal, side by side / one above another
  - **Grid**: as square as it gets, a short last row spread across
  - **One at a Time**: each window fills the whole area
  - **Full Screen**: each window fills the screen, one over another (the focused one on top), right under the menu bar, with the apps across the top: FILE · SURF · HEAR · NOTE, the app in front in full ink, a click goes to one. In the menu bar while it stays; on the desk where it would be while it hides, spread evenly across the screen

  Pick one in the right-click menu or with **⌘1…⌘8** in the Re apps (both also turn tiling on), or step through them with **⌃⌥Space**; the choice is kept. **⌃⌥↩** makes the focused window the main one, **⌃⌥⇧ arrows** move it to its neighbour's place. Windows glide to their places (ease-out, a third of a second; instant with Reduce Motion). They are held there like magnets: a window moved by hand goes back when the mouse is let go, and one dragged onto another's place swaps with it, the place lighting up while it is dragged over. Pulling a window's edge resizes it within the arrangement: the cut between it and its neighbour moves, and the neighbour gives way as it goes (no part narrower than 240 points). **⌃⌥⌘ arrows** do the same from the keyboard: the border between the focused window and its neighbour moves that way, 80 points at a time, so a window on the left grows with → and one on the right with ← (the border on the right, or below, when the window has neighbours on both sides). The sizes are kept per arrangement and number of windows until ReDesk quits; choosing the arrangement already in use evens them out again. One at a Time and Full Screen have nothing to share, so there a resized window goes back. Minimised, hidden and full-screen windows are left alone. Moving other apps' windows needs the Accessibility permission, which macOS asks for when tiling is first turned on. The build is signed ad-hoc but known by its identifier (see `build.sh`), so the permission stays from one build to the next.

**Keys**

| Keys | Where | What |
|---|---|---|
| ⌃⌥← ⌃⌥→ ⌃⌥↑ ⌃⌥↓ | anywhere | focus the nearest window that way (in One at a Time: back and forth through them) |
| ⌃⌥⇧← ⌃⌥⇧→ ⌃⌥⇧↑ ⌃⌥⇧↓ | anywhere, while tiling | the focused window trades places with the nearest one that way (in One at a Time: moves back / forth in the turn) |
| ⌃⌥T | anywhere | tiling on / off |
| ⌘1…⌘8 | in the Re apps | an arrangement, tiling on |
| ⌃⌥Space | anywhere | next arrangement |
| ⌃⌥↩ | anywhere | the focused window becomes the main one |
| ⌘↑ / ⌘↓ | in the Re apps | the focused window fills the screen / the desk's middle; tiling stops |
| ⌘⇧↑ / ⌘⇧↓ | in the Re apps | previous / next wallpaper |
| ⌘⇧T | anywhere | the Mac between light and dark (through System Events: macOS asks once) |

The ⌘ keys are taken only while a Re app is in front, so they keep their usual meaning everywhere else (and lose it inside the Re apps: ⌘↑ / ⌘↓ no longer jump to the top / bottom of a text there). They are read with an event tap, which needs the same Accessibility permission as tiling.

**Ink cursors**: the Re apps' brush-drawn arrow, I-beam and pointing hand become the whole Mac's cursors (light ink while the Mac is dark), set in CoreGraphics' cursor registry the way Mousecape does it; macOS 26 draws the arrow and the I-beam from new names (`…ArrowS`, `…IBeamS`), the old ones are set too for older systems. They go when ReDesk quits, or with right click › Ink Cursors.

Empty parts are at 25%, filled ones (and the chosen wallpaper) at 50%. The ink follows the Mac's appearance, whatever the wallpaper: white in dark mode, a near black in light mode. A right click on a bar shows the time or the battery level.

The pieces sit just above the desktop icons and below every window, in the apps' side-button lettering (Noto Sans JP, upright, one letter every 32pt).

```sh
./build.sh            # build/ReDesk.app
```

Then copy `build/ReDesk.app` to `/Applications/ReSpace` (next to the other Re apps) and open it.
