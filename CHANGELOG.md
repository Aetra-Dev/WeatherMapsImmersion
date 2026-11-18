# Changelog

## 0.1.4
- Second retune for faint haze: mid-range storms (a real sandstorm read about 0.5) now map to a stronger visual intensity for the haze, cloud and puff layers, and a new master knob `/weathermaps strength <0.3-2.5>` (default 1.2) scales all of them. Particle counts still follow the raw intensity.

## 0.1.3
- Retune: haze read too faint with the cloud layer on, so every style gets a stronger haze (snow x1.2, rain x1.35, sandstorm x1.3 of the haze strength), cloud default 0.8, puff opacity default 0.33. Saved `cloud` and `puffalpha` values still at the old defaults are moved once; anything you set yourself is kept.

## 0.1.2
- Large soft puffs (the same puff sprite, 6 at full intensity) drift across both maps in snow, rain and sandstorms and fade in and out, including over the minimap centre, so visibility varies there too. `/weathermaps puffs <0-14>` and `puffalpha <0-1>` tune them.

## 0.1.1
- Cloud art: `puff.tga` (soft puff sprite) now draws the sandstorm dust. `haze_tile.tga` is a seamless cloud tile that drifts over the haze to break up the flat colour (`/weathermaps cloud <0-1>`, 0 = off). `ring_mask.tga` keeps that layer round with a clear centre on the minimap. New texture files: full game restart needed.
- Sandstorm style (tan haze, sideways dust specks), untested because none has been seen yet. `/weathermaps preview sand`.
- Unknown weather types (Miscellaneous, anything new) now show as their enum name or `Type<n>` in debug output instead of reading as Clear.

## 0.1.0
- First clean addon built from WeatherMapProbe: weather-driven snow and rain on the minimap and world map, animated minimap vignette, indoor hiding, world map zone gating, `/weathermaps` commands and saved settings.
- SavedVariables table is set up in `ADDON_LOADED` (the probe created it at file load, so its saved settings never persisted).
- First build from the feasibility probe.
