# glittercursor

Glitter — a tiny macOS menu bar utility that trails sparkles behind your
cursor system-wide. Transparent, click-through overlay window; no
accessibility permissions required (cursor position is polled via
`NSEvent.mouseLocation`, not an event tap).

## Build & run

```
chmod +x build.sh
./build.sh
open Glitter.app
```

Requires the Xcode command line tools (`xcode-select --install` if
`swiftc` is missing).

Quit from the menu bar: ✨ → Quit Glitter.

## Tuning

Particle behavior (birth rate, lifetime, gravity, spin, etc.) can be
overridden without recompiling:

```
defaults write local.glitter.cursor birthRate -float 400
defaults write local.glitter.cursor gravity -float -220
```

Delete an override to fall back to the built-in default:

```
defaults delete local.glitter.cursor birthRate
```

Palette choice and the on/off toggle are remembered across launches.
