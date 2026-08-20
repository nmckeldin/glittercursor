# glittercursor

Glitter — a macOS menu bar utility for screen-shared demos and live
training. It overlays your whole desktop with:

- **Cursor pointer effects** — Glitter (sparkle trail), Click Ripple
  (expanding ring on every click, great for showing remote viewers exactly
  where/when you clicked), Spotlight (dims everything except a circle
  around your cursor), or Laser Pointer (a bright glowing dot with a
  white outline, sized to read clearly on its own — see the permissions
  note below for why it doesn't also hide the system arrow next to it).
- **Annotate Mode** — draw freehand on top of whatever you're presenting,
  in a choice of colors, with undo and clear-all.
- **Hotkeys** to switch effects without touching the mouse, so you never
  have to break your presenting flow to reach the menu bar:

  | Hotkey | Effect |
  |---|---|
  | ⌃⌥1 | Glitter |
  | ⌃⌥2 | Click Ripple |
  | ⌃⌥3 | Spotlight |
  | ⌃⌥4 | Laser Pointer |

Transparent, click-through overlay window. Cursor position is polled via
`NSEvent.mouseLocation`, clicks are observed with a global mouse monitor,
and the hotkeys above are registered with the classic Carbon Hot Key API
— none of that needs Accessibility or Input Monitoring access. (NSEvent's
global *keyboard* monitor would need Input Monitoring; Carbon's
`RegisterEventHotKey` instead claims one specific key combo with the OS,
so nothing is watching your keystrokes and no permission prompt appears.
Annotate Mode itself still has no dedicated hotkey — reachable from the
✨ menu, or you can ask for one to be added the same way if you'd find it
useful.)

**One exception: Laser Pointer requests Accessibility access,** in an
attempt to also hide the system arrow next to the dot. It doesn't
actually manage to — and after digging into why, that turns out to be
structural, not a bug to keep chasing: cursor rendering at a given pixel
belongs to whichever app's window is actually focused and under the
cursor. Full-screen apps like QuickTime or Keynote can hide the cursor
during playback because *they* are that app at that moment. Glitter's
overlay is deliberately click-through, precisely so it never steals your
interaction with whatever you're actually presenting — which means it's
never the focused app, and so it can't claim cursor ownership either,
no matter what permission it's granted. The Accessibility prompt (and
the code behind it) stays in the app as a harmless best-effort attempt
in case some future macOS version changes this, but the honest fallback
is the dot's own visual weight: bright, glowing, white-outlined, sized
to read clearly on its own even with the plain arrow sitting next to it.
If you decline the Accessibility prompt, nothing else in the app is
affected.

## Build & run

```
chmod +x build.sh
./build.sh
open Glitter.app
```

Requires the Xcode command line tools (`xcode-select --install` if
`swiftc` is missing).

First launch: macOS will say it can't verify the developer — right-click
`Glitter.app` → Open → confirm. After that it opens normally.

Quit from the menu bar: ✨ → Quit Glitter.

## Using it for a webinar

1. Pick a pointer effect from ✨ → **Effect**. **Click Ripple** or
   **Spotlight** read as more "presenter tool," less "confetti" — good
   defaults for training content. **Glitter** is still there if you want
   it (with a **Dragon's Breath** palette, if you're feeling festive).
2. When you need to draw on the screen, click ✨ → **Annotate Mode**.
   While it's on, *all* clicks go to drawing — nothing reaches the app
   you're presenting — same tradeoff Zoom/Loom's own annotate tools make.
   Toggle it off from the menu to go back to normal, or just press
   **Escape** — that always works, even if the menu bar itself is
   momentarily hard to reach.
3. Pick a color under ✨ → **Annotation Color**. **Undo Last Stroke** and
   **Clear Annotations** are in the same menu.

Before relying on this live, confirm your screen-share/recording software
actually picks up the overlay window — it should (screen capture normally
includes other visible windows), but worth a quick test run first.

## Tuning

Particle/effect behavior can be overridden without recompiling:

```
defaults write local.glitter.cursor birthRate -float 400
defaults write local.glitter.cursor gravity -float -220
defaults write local.glitter.cursor spotlightRadius -float 180
defaults write local.glitter.cursor rippleMaxRadius -float 70
```

Delete an override to fall back to the built-in default:

```
defaults delete local.glitter.cursor birthRate
```

Effect, palette, annotation color, and the on/off toggle are remembered
across launches. Annotate Mode always starts off, so you never launch
straight into a state where clicks don't reach your other apps.
