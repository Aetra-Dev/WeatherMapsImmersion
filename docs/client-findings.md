# WoW Forever weather: client findings

Client: WoW Forever **1.60.1.70938**, Interface 16001. Tested in-game on 2026-11-16 and 2026-11-17 with a diagnostic probe addon (not part of this repository). Every "verified in game" item comes from in-game logs and screenshots; the author could not run the client unattended.

## Verdicts

| Area | Verdict | Verified in game | Open |
|---|---|---|---|
| Live weather detection | **Feasible** | `C_Weather.GetCurrentWeather()` returns `{type, intensity}`; `WEATHER_CHANGED` fires on every change (no args, new state readable at once, the 2 s poll never saw a change first). Captured one snow storm (42:34) and one rain storm (53:59), start to end, plus `/reload` mid-storm. | A second storm of each type, to see whether the intensity values and stage timings repeat. Rain intensity maps to heavier weather; snow does not (see below). |
| Minimap overlay | **Feasible, one limit** | Circular mask, click-through, layering (+1), vignette haze with drift and breathing, snow and rain looks, indoor hiding. | The arrow, tracking dots and pins are drawn by the Minimap widget, so they are always under the overlay. Only a clear centre and low haze keep them readable. Rotation and minimap zoom were not specifically tested. Caves: one indoor stretch sampled. |
| World map overlay | **Feasible** | Child of `WorldMapFrame.ScrollContainer` at +1: above the map art, below pins and controls; click-through; zoom, pan, windowed and maximized all work; only shown on the player's own zone map. | None known. |

## What the client exposes (verified)
- `C_Weather.GetCurrentWeather()` returns a table `{type, intensity}`. `Enum.WeatherType`: Clear 0, Rain 1, Snow 2, Sandstorm 3, Miscellaneous 4. Sandstorm was seen once (see below); Miscellaneous never.
- `WEATHER_CHANGED` takes no arguments. Read the API after it fires.
- Minimap: 198x198, level 3, strata LOW. `Minimap:GetMaskTexture`, `SetBlipTexture`, `SetPlayerTexture` and `GetMinimapShape` do not exist. `Interface\CharacterFrame\TempPortraitAlphaMask` works as a circular mask.
- Frames, textures and animation: `SetClipsChildren`, `CreateMaskTexture`, `AddMaskTexture`, `SetTexCoord`, `SetRotation`, `SetBlendMode`, `CreateAnimationGroup` all exist. A custom 256x256 RGBA `.tga` loaded and worked (after a full client restart; new files are not picked up by `/reload`).
- `IsIndoors()` and `IsOutdoors()` both flip inside real buildings, but lag the zone event by 0.6 to 1.5 s. A re-check 1.5 s after each zone event plus a 2 s poll hides the overlay in about 1 to 2 s (inn, blacksmith, distillery, one indoor stretch).
- The probe's saved settings and log never persisted. Cause (my bug): it created `WeatherMapProbeDB` at file load, but WoW assigns the saved table just before `ADDON_LOADED`, which replaced the probe's table with the stale file contents. The production addon sets its table up in `ADDON_LOADED`. (An earlier version of this report wrongly blamed `/reload`.) Use `/wmp copy` for live logs.

## Weather behaviour observed

**Snow storm, Dun Morogh, 42 min 34 s**

| Time | Reading | Stage |
|---|---|---|
| 16:01:14 | Snow 0.623 (from Clear) | 17:34 |
| 16:18:48 | Snow 0.704 | 17:00 |
| 16:35:48 | Snow 1.0 (observer: fog and most effects stopped here) | 8:00 |
| 16:43:48 | Clear 0 | |

**Rain storm, Elwynn (Goldshire), 53 min 59 s**

| Time | Reading | Stage |
|---|---|---|
| 17:41:31 | Rain 0.615 ("light rain, mild fog") | 28:59 |
| 18:10:30 | Rain 0.938 ("heavy rain, heavy fog, lightning and thunder") | 25:00 |
| 18:35:30 | Clear 0 | |

- Weather is regional, not strictly per zone. The reading was the same across Kharanos and Coldridge subzones, but Northshire Valley read Clear while the area just outside it was raining. Crossing the boundary re-sends the local state. The Northshire result fits the idea that starting areas are protected, but that is one sample.
- Intensity values belong to the storm: 0.61476880311966 came back to the digit on re-entry.
- Stages last whole minutes (:30 and :48 seconds offsets), which suggests a server-side tick. Two storms only.
- For rain, higher intensity means heavier weather. For snow, the 1.0 stage lost its fog, so snow is not monotonic. The overlay therefore treats the types separately.
- A `Clear` event with intensity 1 arrived 18 minutes before the rain started and may be a pre-storm stage. One sample.
- Not seen: weather density (CVar `weatherDensity`) was 3 throughout, so its effect on the signal is unknown.

**Sandstorm, Tanaris (Gadgetzan), one short sample on 2026-11-17**

| Time | Reading | Notes |
|---|---|---|
| 17:58:20 | Sandstorm (type 3) 0.568 | at login, map = continent |
| 17:58:22 | Sandstorm 0.504 | `WEATHER_CHANGED`, then the zone event gave Tanaris / Gadgetzan |

- Type 3 is Sandstorm and is reported through the same API as snow and rain. Start, end, stage timings and the intensity range were not captured. A cross-check with another weather addon showed the same single API (`C_Weather.GetCurrentWeather`) and no separate source for fog.

## Overlay design that worked
- **Minimap:** child of `Minimap` at level +1 (offsets <= 0 hide it under the terrain; >= 2 starts to cover the compass ring decorations). Circular mask, mouse disabled. Haze is a baked vignette (clear centre, hazy rim) whose texcoord window grows or shrinks with intensity, with a slow drift and a randomised breathing term (default `vigbreath` 0.05).
- **World map:** child of `ScrollContainer` at +1, **no `SetClipsChildren`** (clipping inside the scroll container made the overlay vanish on every other open). Shown only when the viewed map equals the player's map.
- **Auto mode:** follows `type` and `intensity`, switches the snow and rain looks by type, hides indoors, and re-checks after zone events.
- **Look tuning:** rain haze +15%; breathing amplitude 0.05; snow haze fades out as intensity goes 0.85 to 1.0 (provisional, one storm).
- **Cost:** 0.19 ms per frame of Lua for 120 particles (FPS was pinned near 30, so FPS is not a useful metric).

## Art and scaling
- One seamless snow tile in UV space can serve both maps if the texcoord extent follows frame width and height. The minimap needs the circular mask. The world map needs none. A single stretched image would distort. Not yet tested with real art.
- The probe uses solid-colour squares (snow) and thin rotated streaks (rain). Replace them with soft flake art. If per-frame cost matters, scroll two or three tile layers in UV space instead of moving individual particles.

## Prior art
CurseForge weather addons (Comfy Rain, Dynamic Azeroth Weather, Weather, Azeroth Alive) draw full-screen overlays or show forecast icons. None draws weather on the minimap or world map, and none hazes the minimap while keeping the centre clear. Based on their listing pages only, not their code.

## Probe commands (diagnostic addon, not included)
`/wmp auto on` (needed after every reload), `/wmp fake snow|rain [intensity]|off` (test without a storm; logs show FAKE), `/wmp mark <note>`, `/wmp style snow|rain`, `/wmp int`, `/wmp vigmax`, `/wmp vigbreath`, `/wmp curve`, `/wmp indoors`, `/wmp worldlocal`, `/wmp copy`, `/wmp api`, `/wmp bench`.

## Smallest prototype
One addon, no required art: weather-driven overlays from `type` and `intensity`, snow and rain looks, minimap vignette at +1, world map unclipped at +1 and only on the player's own zone, hidden indoors. Next steps are soft flake art, a scrolling tile if needed, and a second storm of each type to confirm the intensity values.
