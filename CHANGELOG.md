# Changelog

## v1.2

- Bound startup scanning to small chunks and revalidate matches before writing.
- Inspect active fire commands first and throttle discovery while ordinary weapons fire.
- Run the assist only from update and disable verbose shot/idle logging by default.
- Preserve continuous fire, second-weapon discovery, callback returns and build checks.
- Add synthetic work-budget and firing regressions; in-game validation is pending.

## v1.1

- Fix startup stopping with "kernel32 bindings unavailable" or a missing
  `GetModuleHandleA` declaration. Declare the API before use and accept native
  LuaJIT function bindings.
- Validate the first update and render callbacks with real Windows bindings,
  including the actual packaged script. Gameplay and build checks are unchanged.

## v1

- Hold the fire button to keep the ARC-3 Arc Thrower firing. The weapon's own
  charge -> fire cycle repeats while the button stays down instead of firing
  once per press and release.
- Follows whichever arc thrower the engine issued a fire command for, including
  a second thrower called down during the same mission.
- Build locked: a known `game.dll` fingerprint is verified before any write, and
  unsupported builds are refused.
- Charge times, cadence, damage, spread and arc settings are stock.
