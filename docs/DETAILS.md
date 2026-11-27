# ReDesk

The Re apps as words in the corners of the desktop: FILE (ReFile) and SURF (ReSurf) at the top, DRAW (ReDraw) and NOTE (ReNote) at the bottom. A click opens the app; a right click can set ReDesk to open at login, or quit it.

Around them:
- **Top**: the battery, a line across the top filled from both its ends toward the middle as far as charged.
- **Right edge**: the wallpapers in `wallpapers/Light` or `wallpapers/Dark`, as the Mac's appearance is (pictures, and videos: mp4 / mov), a dash each one above another, as the desktops on the left (the one on the desk longer and stronger); when the appearance changes (⌘⇧T, say) the desktop takes the other folder's wallpaper, the one last chosen there or its first. The folders stay out of git (too big). A click sets one, **⌥← / ⌥→** step through them (on the desk and in the Re apps, see Keys). The old wallpaper fades into the new one (once a new video has its first frame); while the new one loads, the old one blurs, draws a little nearer and darkens, breathing, so the new one comes into focus. Settings › Wallpaper › Blur wallpaper blurs it, a picture or a video, fading as it turns on or off (kept between launches).
- Videos play muted and looping under the desktop icons on every screen, and pause while the displays sleep. A still of the first frame (kept in `~/Library/Application Support/ReDesk`) is set as the macOS wallpaper underneath, so the choice survives a restart.
- **Left edge**: ReDesk's own desktops, a dash each (see Desktops below). (The day's line, how much of the day has gone, is out for now.)
- **Bottom**: while sound plays, three soft lines drift like a wave, as high as the sound is loud; in silence they settle flat and away. The loudness comes from a Core Audio tap, so macOS asks once for permission to capture audio (nothing is recorded or kept).

**Tiling** (right click › Tile Windows, or **⌘.**): the windows of the Re apps (ReFile, ReSurf, ReDraw, ReNote) share the middle of the desk, between the side columns, 40pt under the day line and over the wave, 10pt apart. One window fills it; with more, the newest is the main one and the arrangement places the rest:
  - **Main and Stack**: the main one on the left half, the others one above another on the right
  - **Main on Top**: the main one across the top 60%, the others side by side under it
  - **Main in the Middle**: the main one in the middle half, the others shared out to the left and the right
  - **Grid** (⌘4): as square as it gets, a short last row spread across
  - **One at a Time** (⌘5): each window fills the whole area, one over another (the focused one on top); with Almost Full, nearly the whole screen
  - **Fibonacci** (⌘6): the golden spiral: the first window the larger part of a golden cut (61.8%), the rest cut again the other way, turning round (left, top, right, bottom…), each new window the next, smaller golden rectangle; resizing moves the cuts as elsewhere

  **Almost Full** (right click › Almost full, or **⌘0** in the Re apps; with any arrangement): the windows share nearly the whole screen instead of the desk's middle, right under the menu bar (no gap) and 10pt from the other edges, with the apps across the top (FILE · SURF · TERM · NOTE, the app in front in full ink, a click goes to one: in the menu bar while it stays, on the desk where it would be while it hides). The desk's own pieces (the corner words, the wallpapers' dashes, the day line, the battery, the wave) fade away while it is on, and come back when it is off. The choice is kept.

**Flush** (⌘9, or Settings › Tile windows › Flush): no room between the tiled windows, and only the outer corners of them all rounded, so they make one window. ReDesk tells each app which of its window's corners are outer and which edges touch another window (a distributed notification, `com.artursavytskyi.re.corners`); the app rounds only those corners (the windows have no rim and cast no shadow, alone or not).

**Desktops**: ReDesk's own, one above another (macOS's Spaces are left alone). Each window of the Re apps is on one, on its own: two windows of one app can be on two desktops. The windows of the others are out of sight (their app puts each away when asked, `hide-window <pid> <window number>`, and back, `show-window …`), and tiling lays out only the one in sight. On the left edge, around its middle, a dash for each, top to bottom, the one in sight longer; a click goes to one. ⌥↑ / ⌥↓ go up and down, ⌘⌃↑ / ⌘⌃↓ take the window in front along (only it, not its app's other windows). As many as are used, and an empty one under them to take a window to; emptied ones go. A new window opens on the desktop in sight; bringing forward an app whose windows are all on another (⌘Tab, the Dock, its corner word) goes to that one. Going down, the windows rise and fade away while the next desktop's fade in rising into their places; going up, the other way. Hide / Show Windows keeps to the desktop in sight. The desktops last while ReDesk runs (windows are known by their numbers, new each launch).

  Pick one in the right-click menu or with **⌘1…⌘6** in the Re apps (both also turn tiling on), or step through them with **⌃⌥Space**; the choice is kept. **⌃⌥↩** makes the focused window the main one, **⌘⌥ arrows** move it to its neighbour's place. **⌃⌥P** pins the focused window to its place, an anchor: windows opening and closing, swaps and a new main one go round it, and it stays where it is (a frame lights up over it for a moment, and the app writes P in the window's top left corner, under the diamond a focused window has there; ⌃⌥P again lets it go, the frame fainter). Windows glide to their places (ease-out, a third of a second; instant with Reduce Motion). They are held there like magnets: a window moved by hand goes back when the mouse is let go, and one dragged onto another's place swaps with it, the place lighting up while it is dragged over. Pulling a window's edge resizes it within the arrangement: the cut between it and its neighbour moves, and the neighbour gives way as it goes (no part narrower than 240 points). **⌘fn arrows** do the same from the keyboard: the border between the focused window and its neighbour moves that way, 80 points at a time, so a window on the left grows with → and one on the right with ← (the border on the right, or below, when the window has neighbours on both sides). The sizes are kept per arrangement and number of windows until ReDesk quits; choosing the arrangement already in use evens them out again. One at a Time has nothing to share, so there a resized window goes back. Minimised, hidden and full-screen windows are left alone. Moving other apps' windows needs the Accessibility permission, which macOS asks for when tiling is first turned on. The build is signed ad-hoc but known by its identifier (see `build.sh`), so the permission stays from one build to the next.

**Keys**

| Keys | Where | What |
|---|---|---|
| ⌘, | on the desk, in the Re apps | settings |
| ⌘/ | on the desk, in the Re apps | every Re app's keys |
| ⌘L | on the desk, in the Re apps | the lock screen (also in the right-click menu, and after 5 minutes untouched unless something keeps the display awake) |
| ⌘J | on the desk, in the Re apps | English / 日本語 |
| ⌘⇧T | anywhere | the Mac between light and dark (through System Events: macOS asks once) |
| ⌘⇧M | anywhere | a video wallpaper stands still, or moves again (kept between launches) |
| ⌘⇧B | anywhere | the wallpaper blurred, or sharp again |
| ⌘← ⌘→ ⌘↑ ⌘↓ | on the desk, in the Re apps | focus the nearest window that way (in One at a Time: back and forth through them) |
| ⌘⌥← ⌘⌥→ ⌘⌥↑ ⌘⌥↓ | on the desk, in the Re apps, while tiling | the focused window trades places with the nearest one that way (in One at a Time: moves back / forth in the turn) |
| ⌘fn← ⌘fn→ ⌘fn↑ ⌘fn↓ | on the desk, in the Re apps, while tiling | the border between the focused window and its neighbour moves that way |
| ⌥↑ / ⌥↓ | on the desk, in the Re apps | the desktop above / below |
| ⌘⌃↑ / ⌘⌃↓ | on the desk, in the Re apps | the window in front to the desktop above / below, and there with it |
| ⌥← / ⌥→ | on the desk, in the Re apps | previous / next wallpaper |
| ⌘= | on the desk, in the Re apps | plus marks on / off |
| ⌘- | on the desk, in the Re apps | Flush on / off |
| ⌘0 | on the desk, in the Re apps | Almost Full on / off |
| ⌘. | on the desk, in the Re apps | tiling on / off |
| ⌘1…⌘6 | on the desk, in the Re apps | an arrangement, tiling on |
| ⌃⌥Space | anywhere | next arrangement |
| ⌃⌥↩ | anywhere | the focused window becomes the main one |
| ⌃⌥P | anywhere, while tiling | pin the focused window to its place / let it go |
| F / S / T / N | on the desk (no app in front but ReDesk or Finder's desktop) | ReFile / ReSurf / ReTerm / ReNote |

The ⌘ and ⌥ keys are taken only while the desk or a Re app is in front, so they keep their usual meaning everywhere else; inside the Re apps they are the desk's, but for ⌘ and ⌥ arrows while something is being typed (a text field has the focus), which stay the text's (but in ReTerm, whose line to type always has the focus, and ReNote). They are read with an event tap, which needs the same Accessibility permission as tiling.

**Ink cursors**: the Re apps' brush-drawn arrow, I-beam and pointing hand become the whole Mac's cursors (light ink while the Mac is dark; the arrow pure white always, its tip sharp, with a dark rim so it reads on a light screen), set in CoreGraphics' cursor registry the way Mousecape does it; macOS 26 draws the arrow and the I-beam from new names (`…ArrowS`, `…IBeamS`), the old ones are set too for older systems. They go when ReDesk quits, or with right click › Ink Cursors.

**Brightness by lid**: on a MacBook with a lid-angle sensor in the hinge, the screen dims as the lid closes (all of the chosen brightness from about 100° open, nearly dark at 20°, eased between; while the lid moves the angle is read 60 times a second, smoothed, and the brightness glides after it). Set the brightness by hand and that becomes the open one. The angle is read from the hinge's HID sensor (Apple 0x05AC:0x8104), the brightness set through DisplayServices; neither is a public API. Off with right click › Brightness by Lid, which gives the chosen brightness back.

**Settings and keys**: two popups (and the dashboard), opening and closing as the apps' windows do (the corners' + first, round the whole width but a quarter of the height; the paper fills them and grows to the whole height; what it shows fades in; closing backwards), in the Re apps' own look (as ReNote's INFO): the paper with its grain (`Resources/noise.png`, the apps' noise.svg) and a 2pt line round it, everything behind blurred (the system's full-screen glass, NSVisualEffectView), the heading in Noto Sans JP spaced wide, the words in Kurale (`Resources/Kurale.woff`, from @fontsource/kurale), the controls as the apps' spaced capitals (ON / OFF, a choice's name opening a list); light or dark as the Mac is (at night the grain multiplied into the paper, as the apps do; an open popup turns with the Mac). Esc, their keys again or a click beside them closes them. **Settings** (⌃⌥, or a right click anywhere on the desk; it replaces the right-click menu; two columns, the desk on the left, the screen and the wallpaper on the right): tiling and its arrangement, ink cursors, dark appearance, glass windows (an experiment: the Re apps' windows as the system's dark blur of what is behind them, written in the desk's white ink, always in the night's look, whatever the Mac's; told to the apps, `com.artursavytskyi.re.glass` with "1" or "0", and read from ReDesk's settings at their start; joined as one in Flush, ReDesk lays one glass under them all, `GlassBackdrop`, a window just under the others, and tells them, "shared" in the corners' word, to drop their own: one glass, no seams; on glass every window, and the glass under them, has square corners), open at login, the language (English or 日本語: the corner words (ファイル, ブラウザ, お絵描き, 覚え書き: four characters, as the English four letters; written down, ー stands up as in vertical writing; the apps across the top too), the popups, the lock screen and the guide's buttons in Japanese, written in Noto Sans JP; the words are in `Sources/Language.swift`, a word not there stays in English; it tells the Re apps too, `com.artursavytskyi.re.language` with the language as its object, and they write their side buttons in it, each app reading it from ReDesk's settings at start); removing this wallpaper (one added from ReFile), the video wallpaper standing still; locking, brightness by lid; quit. **Keys** (⌃⌥/): one wide sheet, a column for each of ReDesk, ReFile, ReSurf, ReDraw and ReNote, all their keys at once. Their lists are written into ReDesk (`KeysPopup.apps`): a key added to an app goes there too. `ReDesk --render-popups <folder> [--light | --dark]` draws both into PNGs (and the corner words, words.png), to look at them without the desk.

Empty parts are at 25%, filled ones (and the chosen wallpaper) at 50%. The ink is always white (as in dark mode), whatever the Mac's appearance or the wallpaper. A right click on a bar shows the time or the battery level.

The pieces sit just above the desktop icons and below every window, in the apps' side-button lettering (Noto Sans JP, upright, one letter every 32pt).

```sh
./build.sh            # build/ReDesk.app
```

Then copy `build/ReDesk.app` to `/Applications/ReSpace` (next to the other Re apps) and open it.

## The focus: the window or the desk

⌃⌥F (anywhere; its own key can be set in the keys popup): a window has the focus (a Re app's diamond, its + strong): the desk takes it (ReDesk in front, no window chosen: the desk's own keys, F / S / T / N, are the keys now). The desk has it: the window that had it before has it again (closed since: the first of the windows).

## Dashboard

⌃⌥D (anywhere; its own key can be set in the keys popup): a popup in the desk's look (`Sources/Dashboard.swift`), the Mac as it is now, read every second while it is open and drawn in the desk's ink — spaced small captions, a large figure, the desk's thin bars, the last minute as a line ending in a diamond. PROCESSORS: how busy (host_processor_info), the cores, the load, how warm (the thermal state). MEMORY: used of all, as Activity Monitor counts it (the apps', wired, compressed), the pressure, swap. DISK: free of all, the bar of what is used. BATTERY: the level, charging (a diamond breathing at the bar's end), time to full or left, its health, cycles, watts and warmth (IOKit's AppleSmartBattery); on a Mac without one, on power. WI-FI: on / off, the network joined, its signal and rate, how fast down and up over the last minute, the networks near (looked for every 20 seconds, the strongest first, four small bars for the signal): a click joins one known or open, a network with a password not known asks for it in its row (Return joins, through networksetup, which keeps it in the keychain). The networks' names need Location (macOS keeps them from apps without it): ALLOW asks for it (the `com.apple.security.personal-information.location` entitlement, NSLocationUsageDescription). At the foot how long the Mac has been on, and the three processes working the processors hardest (ps). `ReDesk --render-popups <folder>` draws it too, after a few seconds' reading.

## Lock screen

⌃⌘L, the right-click menu's Lock Screen, or 5 minutes with nothing touched (the `lockAfterMinutes` default; 0 turns that off; a playing video or anything else keeping the display awake holds it off): the desk's own screen over every other window, the Dock and the menu bar hidden and ⌘Tab, Force Quit and logging out held. The wallpaper (a video one moving, unless frozen with ⌘⇧M) under a light veil; UNLOCK down the middle, a letter to a step as the desk's words. A click on it, Return or any letter opens the password's own field in its place, as the apps' windows open (UNLOCK fading, the corners' + round a quarter of its height, the box growing to its height, the diamonds coming in; Escape closes it backwards) (on the apps' glass, a + at each corner, a diamond in white ink for each letter, in its very middle, the caret blinking after them); Return tries the Mac's password against this account (OpenDirectory, as the Mac's own lock does), a wrong one shakes the box and empties it, Escape puts it away. No Touch ID, no system prompt. It is a window over a Mac still unlocked, so after 10 minutes on it the Mac's own lock comes too; unlocking that lets this screen go.

