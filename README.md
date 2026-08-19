# glittercursor

Glitter — a macOS menu bar utility for screen-shared demos and live
training. It overlays your whole desktop with:

- **Cursor pointer effects** — Glitter (sparkle trail), Click Ripple
  (expanding ring on every click, great for showing remote viewers exactly
  where/when you clicked), Spotlight (dims everything except a circle
  around your cursor), or Laser Pointer (a simple glowing tracking dot).
- **Annotate Mode** — draw freehand on top of whatever you're presenting,
  in a choice of colors, with undo and clear-all.

Transparent, click-through overlay window; no special permissions
required. Cursor position is polled via `NSEvent.mouseLocation` and clicks
are observed with a global mouse monitor — neither needs Accessibility or
Input Monitoring access. (A global keyboard hotkey for Annotate Mode was
deliberately left out, since that specifically would require Input
Monitoring permission — everything's reachable from the ✨ menu instead.)

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
