-- WeatherMaps: Immersion
-- Live weather (snow, rain, sandstorm) drawn over the minimap and the world map. A haze closes in
-- around the player's position as the storm builds. Weather comes from C_Weather.GetCurrentWeather()
-- (WoW Forever client 1.60.x). MIT licensed, (c) 2026 AetraDev.
local ADDON = ...

local DB

local DEFAULTS = {
    enabled     = true,
    minimap     = true,   -- draw on the minimap
    worldmap    = true,   -- draw on the world map
    density     = 60,     -- particles at full intensity (max 150, rain uses 1.6x)
    speed       = 1,      -- particle speed multiplier
    haze        = 0.85,   -- minimap rim haze strength at full intensity (0..1)
    worldHaze   = 0.15,   -- world map flat haze strength at full intensity (0..1)
    breath      = 0.05,   -- how much the clear zone swells and shrinks (0 = static)
    vigRange    = 0.30,   -- how much the clear zone grows as intensity falls
    hideIndoors = true,   -- no weather overlay inside buildings
    worldLocal  = true,   -- world map overlay only on the map of the zone you stand in
    snowFade    = true,   -- snow haze fades out as intensity nears 1.0 (provisional)
    fadeLo      = 0.85,   -- intensity where that fade starts
    cloud       = 0.8,    -- strength of the drifting cloud layer that breaks up the haze (0 = off)
    strength    = 1.2,    -- master multiplier for every haze layer (haze, cloud, puffs); 1 = old look
    puffs       = 6,     -- large soft puffs drifting over the map at full intensity (0 = off, max 14)
    puffAlpha   = 0.33,   -- peak opacity of those puffs (0..1)
    debug       = false,
}

local MAXP = 150
local MAXPUFF = 14
local VIG_PATH  = "Interface\\AddOns\\WeatherMapsImmersion\\haze_vignette.tga"
local MASK_PATH = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local PUFF_PATH = "Interface\\AddOns\\WeatherMapsImmersion\\puff.tga"          -- soft cloud sprite (dust/sand)
local TILE_PATH = "Interface\\AddOns\\WeatherMapsImmersion\\haze_tile.tga"      -- seamless cloud tile (haze)
local RING_PATH = "Interface\\AddOns\\WeatherMapsImmersion\\ring_mask.tga"      -- circle + clear centre for the minimap cloud

-- Looks. `kind` picks the particle look: "snow" squares, "rain" streaks, "dust" wide sideways-blown
-- specks. `mult` scales the particle count. Sandstorm is untested: it has never been seen in game.
local STYLES = {
    -- cloudV = cloud layer drift in tile widths per second (x, y)
    -- puffV = big-puff drift in px/s on a 140 px frame (x, y)
    Snow      = { haze = { 0.85, 0.92, 1.00 }, kind = "snow", mult = 1.0, hazeMul = 1.2,  cloudV = { -0.006, 0.004 }, puffV = { -6, -3 } },
    Rain      = { haze = { 0.42, 0.47, 0.55 }, kind = "rain", mult = 1.6, hazeMul = 1.35, cloudV = { -0.012, 0.006 }, puffV = { -14, -5 } },
    Sandstorm = { haze = { 0.80, 0.62, 0.36 }, kind = "dust", mult = 1.5, hazeMul = 1.3,  cloudV = { -0.050, 0.004 }, puffV = { -55, -2 } },
}

local state = { style = "Snow", intensity = 0, active = false, preview = nil, lastKey = nil }
local list = {}          -- surfaces in draw order
local driver = CreateFrame("Frame")
local vigT, gateAcc = 0, 0

local function dbg(fmt, ...)
    if DB and DB.debug then
        local ok, s = pcall(string.format, fmt, ...)
        print("|cff66ccffWMI|r " .. (ok and s or tostring(fmt)))
    end
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- Visual intensity for the haze layers: lifts mid-range storms (a real sandstorm read about 0.5, which
-- looked faint) while 1.0 stays 1.0. Particle counts still follow the raw intensity.
local function vis(I) return clamp(0.3 + 0.7 * I, 0, 1) end

---------------------------------------------------------------- weather and indoor state
local typeNames
local function typeName(t)
    if not typeNames then
        typeNames = {}
        if Enum and Enum.WeatherType then
            for k, v in pairs(Enum.WeatherType) do typeNames[v] = k end
        else
            typeNames = { [0] = "Clear", [1] = "Rain", [2] = "Snow", [3] = "Sandstorm" }
        end
    end
    if t == nil then return "Clear" end
    return typeNames[t] or ("Type" .. tostring(t))   -- unknown types stay visible in /weathermaps debug
end

-- name ("Clear", "Rain", "Snow", ...) and intensity 0..1 for the player's position
local function currentWeather()
    if state.preview then return state.preview.name, state.preview.intensity end
    if not (C_Weather and C_Weather.GetCurrentWeather) then return "Clear", 0 end
    local ok, w = pcall(C_Weather.GetCurrentWeather)
    if not ok or type(w) ~= "table" then return "Clear", 0 end
    return typeName(w.type), tonumber(w.intensity) or 0
end

-- IsIndoors() and IsOutdoors() both flip inside real buildings, but lag the zone event by 0.6-1.5 s.
local function isIndoors()
    local okI, ind = pcall(IsIndoors)
    local okO, outd = pcall(IsOutdoors)
    return (okI and ind and true) or (okO and not outd) or false
end

---------------------------------------------------------------- minimap vignette (animated haze)
local function hazeColor(s) return STYLES[s.styleName or "Snow"].haze end

-- Snow haze weight. In the captured storm the fog ended when intensity reached 1.0, so snow haze
-- fades out near 1.0 while the particle count still follows intensity. Rain keeps scaling up.
local function hazeWeight(s)
    local style = STYLES[s.styleName or "Snow"]
    if DB.snowFade and (s.styleName or "Snow") == "Snow" then
        local x = clamp((s.intensity - DB.fadeLo) / (1 - DB.fadeLo), 0, 1)
        return (1 - x * x * (3 - 2 * x)) * (style.hazeMul or 1)
    end
    return style.hazeMul or 1
end

local function applyHazeStyle(s)
    if not s.haze then return end
    local c = hazeColor(s)
    if s.cloud then s.cloud:SetVertexColor(c[1], c[2], c[3], 1) end
    if s.puffs then
        for i = 1, MAXPUFF do s.puffs[i].tex:SetVertexColor(c[1], c[2], c[3], 1) end
    end
    if s.key == "mini" then
        s.haze:SetTexture(VIG_PATH)
        s.haze:SetVertexColor(c[1], c[2], c[3], 1)
        s.haze:SetTexCoord(0.06, 0.94, 0.06, 0.94)
        s.vigOn = true
    else
        s.haze:SetColorTexture(c[1], c[2], c[3], 1)
        s.haze:SetTexCoord(0, 1, 0, 1)
        s.vigOn = false
    end
end

-- The image is white with alpha 0 in the centre rising to 1 at the rim. Intensity widens the texcoord
-- window (smaller clear zone). Slow sines plus a smoothed random walk make it drift and breathe.
local function vigStep(s, t, dt)
    local I = vis(s.intensity)
    local h = 0.40 - DB.vigRange * (1 - I)
    local dx = 0.012 * math.sin(t * 0.37) + 0.008 * math.sin(t * 1.1)
    local dy = 0.012 * math.cos(t * 0.29) + 0.008 * math.sin(t * 0.83)
    local cx, cy = 0.5 + dx, 0.5 + dy
    local d = math.sqrt(dx * dx + dy * dy) / 0.014
    s.nTimer = (s.nTimer or 0) - dt
    if s.nTimer <= 0 then s.nTarget = math.random() * 2 - 1; s.nTimer = 1.5 + math.random() * 3 end
    s.n = (s.n or 0) + (s.nTarget - (s.n or 0)) * math.min(1, dt * 0.8)
    local b = 0.35 * math.sin(t * 0.9 + 0.8 * math.sin(t * 0.13))
            + 0.20 * math.sin(t * 2.3 + 1 + 1.1 * math.sin(t * 0.21))
            + 0.35 * (d - 0.6) + 0.6 * s.n
    h = h * (1 + DB.breath * b)
    local lim = 0.5 - math.max(math.abs(dx), math.abs(dy))   -- keep the window inside the image
    if h > lim then h = lim end
    s.haze:SetTexCoord(cx - h, cx + h, cy - h, cy + h)
    s.haze:SetAlpha(clamp(DB.haze * (0.35 + 0.65 * I) * (0.95 + 0.05 * math.sin(t * 1.7))
        * (1 - 0.5 * DB.breath * b) * hazeWeight(s) * DB.strength, 0, 1))
end

---------------------------------------------------------------- particles
local function newParticleState(w, h, kind)
    if kind == "dust" then
        return {
            x = math.random() * w, y = math.random() * h,
            vx = -(90 + math.random() * 90), vy = -(4 + math.random() * 14),
            t = math.random() * 6, wf = 1 + math.random() * 2, wa = 0.5 + math.random() * 1.5,
            a0 = 0.25 + math.random() * 0.4,
        }
    end
    if kind == "rain" then
        return {
            x = math.random() * w, y = math.random() * h,
            vx = -(30 + math.random() * 25), vy = -(260 + math.random() * 110),
            t = 0, wf = 0, wa = 0, a0 = 0.3 + math.random() * 0.4,
        }
    end
    return {
        x = math.random() * w, y = math.random() * h,
        vx = -(15 + math.random() * 25), vy = -(25 + math.random() * 35),
        t = math.random() * 6, wf = 1 + math.random() * 2, wa = 2 + math.random() * 4,
        a0 = 0.5 + math.random() * 0.5,
    }
end

-- Snow = small white square, rain = thin streak leaning with the wind.
local function stylePar(p, kind)
    local tex = p.tex
    if kind == "dust" then
        local sz = 9 + math.random() * 14               -- soft cloud puff, stretched sideways
        tex:SetTexture(PUFF_PATH)
        tex:SetVertexColor(0.92, 0.78, 0.52, 1)
        tex:SetSize(sz * 1.5, sz * 0.8)
        tex:SetRotation(0)
    elseif kind == "rain" then
        tex:SetSize(1.2, 7 + math.random() * 9)
        tex:SetColorTexture(0.78, 0.85, 0.95, 1)
        tex:SetVertexColor(1, 1, 1, 1)
        tex:SetRotation(-math.atan(math.abs(p.st.vx) / math.abs(p.st.vy)))
    else
        local sz = 1.5 + math.random() * 2.5
        tex:SetSize(sz, sz)
        tex:SetColorTexture(1, 1, 1, 1)
        tex:SetVertexColor(1, 1, 1, 1)
        tex:SetRotation(0)
    end
    tex:SetAlpha(p.st.a0)
end

-- Large soft puffs that swell in and fade out across the whole frame, the clear centre included, so
-- visibility varies there too. Kept faint so the arrow and dots stay readable.
local function newPuffState(w, h)
    local life = 6 + math.random() * 7
    return {
        x = math.random() * w, y = math.random() * h,
        life = life, t = 0, size = w * (0.22 + math.random() * 0.30),
        stretch = 0.75 + math.random() * 0.5, peak = 0.5 + math.random() * 0.5,
        rot = math.random() * 6.283,
    }
end

local function stylePuff(p)
    local st = p.st
    p.tex:SetSize(st.size * st.stretch, st.size)
    p.tex:SetRotation(st.rot)
end

local function applyIntensity(s)
    if not s.frame then return end
    local style = STYLES[s.styleName or "Snow"]
    local n = math.min(MAXP, math.floor(DB.density * style.mult * s.intensity + 0.5))
    s.activeN = n
    s.puffN = math.min(MAXPUFF, math.floor(DB.puffs * (0.3 + 0.7 * s.intensity) + 0.5))
    if not s.vigOn then
        s.haze:SetAlpha(clamp(DB.worldHaze * vis(s.intensity) * hazeWeight(s) * DB.strength, 0, 1))
    end
    for i = 1, MAXP do
        local tex = s.parts[i].tex
        if i <= n then tex:Show() else tex:Hide() end
    end
end

local function applyStyle(s, name)
    if not s.frame or s.styleName == name then return end
    s.styleName = name
    local kind = STYLES[name].kind
    local w, h = s.frame:GetWidth(), s.frame:GetHeight()
    for i = 1, MAXP do
        local p = s.parts[i]
        p.st = newParticleState(w > 0 and w or 140, h > 0 and h or 140, kind)
        stylePar(p, kind)
    end
    applyHazeStyle(s)
    applyIntensity(s)
end

local function stepSurface(s, dt)
    local f = s.frame
    local w, h = f:GetWidth(), f:GetHeight()
    if not w or w <= 0 then return end
    if not s.sized then
        -- the surface may have been built while its parent was hidden (size 0x0): spread particles over the real size
        s.sized = true
        for i = 1, MAXP do
            local st = s.parts[i].st
            st.x = math.random() * w; st.y = math.random() * h
        end
        if s.puffs then   -- same for the big puffs: size them from the real frame size
            for i = 1, MAXPUFF do
                local p = s.puffs[i]
                p.st = newPuffState(w, h); p.st.t = math.random() * p.st.life
                stylePuff(p)
            end
        end
    end
    if s.cloud then
        local cv = STYLES[s.styleName or "Snow"].cloudV
        s.co = ((s.co or math.random()) + cv[1] * dt * DB.speed) % 1
        s.cp = ((s.cp or math.random()) + cv[2] * dt * DB.speed) % 1
        local m = math.max(w, h)
        s.cloud:SetTexCoord(s.co, s.co + 0.7 * w / m, s.cp, s.cp + 0.7 * h / m)
        s.cloud:SetAlpha(clamp(DB.cloud * (0.35 + 0.65 * vis(s.intensity)) * hazeWeight(s) * DB.strength
            * (s.key == "world" and 0.5 or 1), 0, 1))
    end
    local sc = math.sqrt(w / 140) * DB.speed
    if s.puffs then
        local pv = STYLES[s.styleName or "Snow"].puffV
        local A = DB.puffAlpha * (0.4 + 0.6 * vis(s.intensity)) * hazeWeight(s) * DB.strength
            * (s.key == "world" and 0.6 or 1)
        for i = 1, MAXPUFF do
            local p = s.puffs[i]
            if i > (s.puffN or 0) then
                p.tex:SetAlpha(0)
            else
                local st = p.st
                st.t = st.t + dt
                if st.t >= st.life then
                    p.st = newPuffState(w, h); st = p.st
                    stylePuff(p)
                end
                st.x = st.x + pv[1] * sc * dt
                st.y = st.y + pv[2] * sc * dt
                if st.x < -st.size then st.x = w + st.size elseif st.x > w + st.size then st.x = -st.size end
                if st.y < -st.size then st.y = h + st.size elseif st.y > h + st.size then st.y = -st.size end
                p.tex:SetPoint("CENTER", f, "BOTTOMLEFT", st.x, st.y)
                p.tex:SetAlpha(clamp(A * st.peak * math.sin(math.pi * st.t / st.life), 0, 1))
            end
        end
    end
    local cx, cy, r = w / 2, h / 2, w / 2
    for i = 1, s.activeN do
        local p = s.parts[i]
        local st = p.st
        st.t = st.t + dt
        st.x = st.x + st.vx * sc * dt
        st.y = st.y + st.vy * sc * dt
        if st.y < -4 then st.y = h + 4; st.x = math.random() * (w + 40) end
        if st.x < -4 then st.x = w + 4 end
        p.tex:SetPoint("CENTER", f, "BOTTOMLEFT", st.x + math.sin(st.t * st.wf) * st.wa, st.y)
        if s.centerClear then   -- keep the arrow area clear of particles on the minimap
            local d = math.sqrt((st.x - cx) ^ 2 + (st.y - cy) ^ 2) / r
            p.tex:SetAlpha(st.a0 * clamp((d - 0.12) / 0.2, 0, 1))
        end
    end
end

---------------------------------------------------------------- surfaces
local function buildSurface(s, parent, levelOffset, maskPath, noClip)
    if s.frame then return true end
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f:SetFrameStrata(parent:GetFrameStrata())
    f:SetFrameLevel(math.max(0, parent:GetFrameLevel() + levelOffset))
    f:EnableMouse(false)                       -- never intercept clicks or tooltips
    -- World map: SetClipsChildren inside the map's scroll container made the overlay vanish on every
    -- other open; the container already bounds it, so the world map overlay is not clipped.
    if f.SetClipsChildren and not noClip then f:SetClipsChildren(true) end
    s.frame = f
    local mask
    if maskPath then
        local ok, m = pcall(function()
            local mk = f:CreateMaskTexture()
            mk:SetAllPoints(f)
            mk:SetTexture(maskPath, "CLAMPTOBORDER", "CLAMPTOBORDER")
            return mk
        end)
        if ok then mask = m end
    end
    local haze = f:CreateTexture(nil, "BACKGROUND")
    haze:SetAllPoints(f)
    if mask then haze:AddMaskTexture(mask) end
    s.haze = haze
    -- Drifting cloud layer over the haze. Minimap: masked by the static ring mask (circle, clear centre)
    -- so the arrow area stays clear; falls back to the plain circle mask if that file fails to load.
    local okc, cloud = pcall(function()
        local c = f:CreateTexture(nil, "BACKGROUND", nil, 1)
        c:SetAllPoints(f)
        c:SetTexture(TILE_PATH, "REPEAT", "REPEAT")
        if maskPath then
            local rm = f:CreateMaskTexture()
            rm:SetAllPoints(f)
            rm:SetTexture(RING_PATH, "CLAMPTOBORDER", "CLAMPTOBORDER")
            c:AddMaskTexture(rm)
        end
        return c
    end)
    if okc then cloud:SetAlpha(0); s.cloud = cloud elseif mask then dbg("cloud layer failed: %s", tostring(cloud)) end
    s.styleName = state.style
    s.intensity = state.intensity > 0 and state.intensity or 1
    applyHazeStyle(s)
    local w, h = f:GetWidth(), f:GetHeight()
    local kind = STYLES[state.style].kind
    -- big puffs sit above the haze and cloud layers and below the small particles
    s.puffs = {}
    for i = 1, MAXPUFF do
        local tex = f:CreateTexture(nil, "ARTWORK")
        tex:SetTexture(PUFF_PATH)
        tex:SetAlpha(0)
        tex:SetPoint("CENTER", f, "BOTTOMLEFT", 0, 0)
        if mask then tex:AddMaskTexture(mask) end
        local p = { tex = tex, st = newPuffState(w > 0 and w or 140, h > 0 and h or 140) }
        p.st.t = math.random() * p.st.life
        stylePuff(p)
        s.puffs[i] = p
    end
    applyHazeStyle(s)   -- tint the puffs now that they exist
    s.parts = {}
    for i = 1, MAXP do
        local tex = f:CreateTexture(nil, "OVERLAY")
        tex:SetPoint("CENTER", f, "BOTTOMLEFT", 0, 0)
        if mask then tex:AddMaskTexture(mask) end
        local p = { tex = tex, st = newParticleState(w > 0 and w or 140, h > 0 and h or 140, kind) }
        stylePar(p, kind)
        s.parts[i] = p
    end
    f:Hide()
    return true
end

local mini = { key = "mini", centerClear = true, activeN = 0, intensity = 1 }
mini.build = function() return buildSurface(mini, Minimap, 1, MASK_PATH, false) end

local world = { key = "world", centerClear = false, activeN = 0, intensity = 1 }

local function worldGateOK()
    if not DB.worldLocal then return true end
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then return true end
    local viewed = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    local mine = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    return viewed ~= nil and mine ~= nil and viewed == mine
end

local function syncShown(s)
    if not s.frame then return end
    local show = s.on and (s.key ~= "world" or worldGateOK()) or false
    if s.frame:IsShown() ~= show then s.frame:SetShown(show) end
end

world.build = function()
    if not WorldMapFrame then return false end
    local parent = WorldMapFrame.ScrollContainer or WorldMapFrame
    local ok = buildSurface(world, parent, 1, nil, true)
    if ok and not world.hooked then
        world.hooked = true
        WorldMapFrame:HookScript("OnShow", function() syncShown(world) end)
    end
    return ok
end

list[1], list[2] = mini, world

local function onUpdate(_, dt)
    vigT = vigT + dt
    gateAcc = gateAcc + dt
    if gateAcc > 0.2 then gateAcc = 0; syncShown(world) end   -- hide on other zones' maps
    if mini.on and mini.frame and mini.frame:IsShown() then vigStep(mini, vigT, dt) end
    for i = 1, #list do
        local s = list[i]
        if s.on and s.frame and s.frame:IsShown() then stepSurface(s, dt) end
    end
end

local function setDriver(on) driver:SetScript("OnUpdate", on and onUpdate or nil) end

local function surfaceWanted(s)
    if not (DB.enabled and state.active) then return false end
    if s.key == "mini" then return DB.minimap end
    return DB.worldmap
end

local function applyVisibility()
    local any = false
    for i = 1, #list do
        local s = list[i]
        local want = surfaceWanted(s)
        if want and not s.frame then want = s.build() end   -- built on first need; false if the parent is missing
        s.on = want and true or false
        if s.frame then syncShown(s) end
        any = any or s.on
    end
    setDriver(any)
end

---------------------------------------------------------------- evaluation
-- Called from WEATHER_CHANGED, zone events, a 2 s poll and any settings change.
local function evaluate(src, force)
    local name, inten = currentWeather()
    local indoors = isIndoors()
    local active = STYLES[name] ~= nil and inten > 0
    if DB.hideIndoors and indoors then active = false end
    local key = name .. tostring(active) .. tostring(inten) .. tostring(indoors)
    if key == state.lastKey and not force then return end
    if key ~= state.lastKey then
        dbg("%s: %s %.3f active=%s indoors=%s", src or "?", name, inten, tostring(active), tostring(indoors))
    end
    state.lastKey = key
    state.active = active
    if active then
        state.style = name
        state.intensity = clamp(inten, 0.15, 1)
    end
    applyVisibility()
    if active then
        for i = 1, #list do
            local s = list[i]
            if s.frame then
                applyStyle(s, name)
                s.intensity = state.intensity
                applyIntensity(s)
            end
        end
    end
end

---------------------------------------------------------------- slash commands
local function onoff(arg, cur)
    if arg == "on" then return true elseif arg == "off" then return false end
    return not cur
end

local HELP = [[
|cff66ccffWeatherMaps: Immersion|r  /weathermaps (or /wmaps)
  (none)              show status
  on | off            enable or disable everything
  minimap [on|off]    minimap overlay            worldmap [on|off]   world map overlay
  preview snow|rain|sand [intensity 0-1] try a look without a storm      preview off
  haze <0-1>          minimap rim haze strength  density <n>         particles at full intensity (max 150)
  speed <x>           particle speed             breath <0-0.3>      clear-zone swell (0 = static)
  indoors [on|off]    hide inside buildings      local [on|off]      world map only on your zone's map
  strength <0.3-2.5>  master multiplier for all haze layers (default 1.2)
  cloud <0-1>         drifting cloud layer in the haze (0 = off)
  puffs <0-14>        big soft puffs drifting over the map (0 = off)      puffalpha <0-1>   their opacity
  snowfade [on|off]   snow haze fades near intensity 1.0
  debug [on|off]      print weather changes      reset               restore defaults]]

local function status()
    local name, inten = currentWeather()
    print(string.format("|cff66ccffWeatherMaps: Immersion|r  enabled=%s  weather=%s %.3f%s  overlay active=%s  indoors=%s",
        tostring(DB.enabled), name, inten, state.preview and " (PREVIEW)" or "", tostring(state.active), tostring(isIndoors())))
    print(string.format("  minimap=%s worldmap=%s haze=%.2f strength=%.2f cloud=%.2f puffs=%d density=%d speed=%.2f breath=%.2f hideIndoors=%s worldLocal=%s snowFade=%s",
        tostring(DB.minimap), tostring(DB.worldmap), DB.haze, DB.strength, DB.cloud, DB.puffs, DB.density, DB.speed, DB.breath,
        tostring(DB.hideIndoors), tostring(DB.worldLocal), tostring(DB.snowFade)))
    print("  /weathermaps help for commands")
end

SLASH_WEATHERMAPSIMMERSION1 = "/weathermaps"
SLASH_WEATHERMAPSIMMERSION2 = "/wmaps"
SlashCmdList["WEATHERMAPSIMMERSION"] = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower(); arg = arg:lower()
    local num = tonumber(arg)
    if cmd == "" or cmd == "status" then status(); return
    elseif cmd == "help" then print(HELP); return
    elseif cmd == "on" then DB.enabled = true
    elseif cmd == "off" then DB.enabled = false
    elseif cmd == "minimap" then DB.minimap = onoff(arg, DB.minimap)
    elseif cmd == "worldmap" then DB.worldmap = onoff(arg, DB.worldmap)
    elseif cmd == "preview" then
        local kind, val = arg:match("^(%S+)%s*(%S*)$")
        local pnames = { snow = "Snow", rain = "Rain", sand = "Sandstorm", sandstorm = "Sandstorm" }
        if pnames[kind] then
            state.preview = { name = pnames[kind], intensity = clamp(tonumber(val) or 0.7, 0, 1) }
            print(string.format("|cff66ccffWMI|r preview %s %.2f (/weathermaps preview off to stop)", kind, state.preview.intensity))
        else
            state.preview = nil
            print("|cff66ccffWMI|r preview off")
        end
    elseif cmd == "haze" and num then DB.haze = clamp(num, 0, 1)
    elseif cmd == "cloud" and num then DB.cloud = clamp(num, 0, 1)
    elseif cmd == "strength" and num then DB.strength = clamp(num, 0.3, 2.5)
    elseif cmd == "puffs" and num then DB.puffs = clamp(math.floor(num), 0, MAXPUFF)
    elseif cmd == "puffalpha" and num then DB.puffAlpha = clamp(num, 0, 1)
    elseif cmd == "density" and num then DB.density = clamp(math.floor(num), 0, MAXP)
    elseif cmd == "speed" and num then DB.speed = clamp(num, 0.1, 5)
    elseif cmd == "breath" and num then DB.breath = clamp(num, 0, 0.3)
    elseif cmd == "indoors" then DB.hideIndoors = onoff(arg, DB.hideIndoors)
    elseif cmd == "local" then DB.worldLocal = onoff(arg, DB.worldLocal)
    elseif cmd == "snowfade" then DB.snowFade = onoff(arg, DB.snowFade)
    elseif cmd == "debug" then DB.debug = onoff(arg, DB.debug)
    elseif cmd == "reset" then
        for k in pairs(DB) do DB[k] = nil end
        for k, v in pairs(DEFAULTS) do DB[k] = v end
        print("|cff66ccffWMI|r settings reset")
    else print(HELP); return end
    evaluate("command", true)
end

---------------------------------------------------------------- startup
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        -- SavedVariables are assigned just before ADDON_LOADED fires, so the table must be set up here,
        -- not at file load.
        WeatherMapsImmersionDB = WeatherMapsImmersionDB or {}
        DB = WeatherMapsImmersionDB
        for k, v in pairs(DEFAULTS) do if DB[k] == nil then DB[k] = v end end
        -- One-time retune (0.1.3): haze read too faint with the cloud layer. Saved values beat new defaults,
        -- so move the two layer settings only if the user left them at the old defaults.
        if (DB.tuneVer or 0) < 1 then
            if DB.cloud == 0.6 then DB.cloud = 0.8 end
            if DB.puffAlpha == 0.25 then DB.puffAlpha = 0.33 end
            DB.tuneVer = 1
        end
        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("ZONE_CHANGED")
        self:RegisterEvent("ZONE_CHANGED_INDOORS")
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        pcall(self.RegisterEvent, self, "WEATHER_CHANGED")
        C_Timer.NewTicker(2, function() evaluate("poll") end)
    elseif event == "WEATHER_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        evaluate(event)
    else
        -- IsIndoors()/IsOutdoors() lag the zone event, so re-check shortly after it as well
        evaluate(event)
        C_Timer.After(0.6, function() evaluate("zone+0.6s") end)
        C_Timer.After(1.5, function() evaluate("zone+1.5s") end)
    end
end)
