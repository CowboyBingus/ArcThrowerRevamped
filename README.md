# Arc Thrower Revamped

Hold the fire button and the ARC-3 Arc Thrower keeps firing. Vanilla charges
while the trigger is held but only fires when it is released, so firing
repeatedly means pressing and releasing over and over; with this addon the
engine's own charge -> fire cycle simply repeats while the button stays down.

Nothing else is changed. Charge times, cadence, damage, spread and the arc's own
settings are stock, and the addon is inert unless the physical fire button is
held and an arc thrower is the weapon the engine issued a fire command for.

## Install

1. Close Helldivers 2.
2. Import `Arc-Thrower-Revamped-v1.1.zip` and **Bingus Shared Loader v15 or
   newer** into Arsenal or HD2MM, then enable both.
3. With Arsenal's default priority, put the loader last at the bottom of the
   load order.
4. Purge / Deploy, then start the game.

Only one mod manager should be used, and older packages that bundle their own
loader should be removed before deploying this one.

## Behaviour and limits

- The first shot of a press is the weapon's own; the addon keeps the cycle
  going after that one.
- Only the physical left mouse button triggers the assist. Holding the button
  while any other weapon is equipped does nothing.
- A second arc thrower called down later has its own entity and charge entry,
  so the addon follows whichever thrower the engine issued a fire command for.
- No executable code is modified. The addon writes the thrower's charge record
  (`auto_fire_in_safety`) and its runtime charge entry, and verifies a known
  `game.dll` fingerprint before touching anything.
- Validated on Steam build 24826606 / EXE 1.8.45317.0 in a solo session. Other
  builds are refused by design.

`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/ArcThrowerAuto.log` records the
build check, the patched charge record, every shot with its interval, a
four-per-second status line while the assist runs, and the reason it is idle
otherwise.

## Build

The addon is one plaintext script discovered by Bingus Shared Loader through
its `-- HD2-Addon:` declaration. Package it from this checkout:

```powershell
python -B scripts/build.py --loader ..\BingusSharedLoader `
  --output releases\Arc-Thrower-Revamped-v1.1.zip
```

The builder runs `python check.py --archive <zip>` before finishing. The check
validates the source and packaged entry with Windows x64 LuaJIT (set
`HD2_LUAJIT` or have `luajit` on `PATH`). It runs the first update and render
callbacks with clean and predeclared native bindings, and checks that a
synthetic unsupported game image is rejected without writes. These offline
checks do not validate live gameplay.

Requires [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader/releases/latest)
v15 or newer (API 1). Artwork is not included; the repository ships source and
the packaged release only.
