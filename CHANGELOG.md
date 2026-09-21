# Changelog

## v1

- Hold the fire button to keep the ARC-3 Arc Thrower firing. The weapon's own
  charge -> fire cycle repeats while the button stays down instead of firing
  once per press and release.
- Follows whichever arc thrower the engine issued a fire command for, including
  a second thrower called down during the same mission.
- Build locked: a known `game.dll` fingerprint is verified before any write, and
  unsupported builds are refused.
- Charge times, cadence, damage, spread and arc settings are stock.
