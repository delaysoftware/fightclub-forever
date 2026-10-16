local _, ns = ...
local Home = ns.Home

local ICON = "Interface\\AddOns\\Fightclub\\Media\\icon"

local function Me() return ns.DisplayName("player") end

-- Gewählter Treffpunkt, sonst der Standard je nach Fraktion. Zweiter Rückgabewert: true = Standard.
function ns.EffectiveHome()
    local c = ns.db and ns.db.home and ns.db.home.current
    if c then return c, false end
    local d = Home.DEFAULTS[UnitFactionGroup("player") or ""]
    if d then return d, true end
end
local function Eligible() return Home.IsEligible(ns.BuildEntries(), Me()) end

----------------------------------------------------------------- Weltkarte
local pick -- Klick-Overlay

local function SetupMap()
    local canvas = WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas() or WorldMapFrame.ScrollContainer.Child

    local pin = CreateFrame("Frame", nil, canvas)
    pin:SetSize(32, 32)
    pin:SetFrameLevel(canvas:GetFrameLevel() + 50)
    pin:EnableMouse(true)
    local tex = pin:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(ICON)
    pin:SetScript("OnEnter", function(self)
        local c, isDefault = ns.EffectiveHome()
        if not c then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Fightclub", 1, 0.25, 0.25)
        GameTooltip:AddLine(c.name, 1, 1, 1)
        if isDefault then
            GameTooltip:AddLine("Default location – no vote has been held yet", 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("since " .. date("%d.%m.%Y", c.since), 0.7, 0.7, 0.7)
        end
        local p = ns.db.home.proposal
        if p then
            local y, n = Home.Tally(p)
            GameTooltip:AddLine(("Vote running: %s (Yes %d / No %d)"):format(p.name, y, n), 1, 0.82, 0)
        end
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:Hide()

    -- Zweiter Pin für den Ort, über den gerade abgestimmt wird: kleiner, bernsteinfarben, mit Fragezeichen.
    local ppin = CreateFrame("Frame", nil, canvas)
    ppin:SetSize(26, 26)
    ppin:SetFrameLevel(canvas:GetFrameLevel() + 51)
    ppin:EnableMouse(true)
    local ptex = ppin:CreateTexture(nil, "OVERLAY")
    ptex:SetAllPoints()
    ptex:SetTexture(ICON)
    ptex:SetDesaturated(true) -- sonst mischt sich das Bernstein mit dem Blau des Wappens
    ptex:SetVertexColor(1, 0.8, 0.2)
    local pq = ppin:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    pq:SetPoint("BOTTOMRIGHT", 6, -6)
    pq:SetText("?")
    ppin:SetScript("OnEnter", function(self)
        local p = ns.db.home.proposal
        if not p then return end
        local y, n = Home.Tally(p)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Fightclub – proposed location", 1, 0.82, 0)
        GameTooltip:AddLine(p.name, 1, 1, 1)
        GameTooltip:AddLine(("Proposed by %s – Yes %d / No %d"):format(p.proposer, y, n), 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Vote with /fc vote yes|no or in the Fightclub tab", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    ppin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ppin:Hide()

    function ns.RefreshMapPin()
        local c = ns.db and ns.EffectiveHome()
        local mapID = WorldMapFrame:GetMapID()
        if c and mapID == c.mapID then
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", canvas, "TOPLEFT", c.x * canvas:GetWidth(), -c.y * canvas:GetHeight())
            pin:Show()
        else
            pin:Hide()
        end
        local p = ns.db and ns.db.home.proposal
        if p and time() < p.startTime + Home.DURATION and mapID == p.mapID then
            ppin:ClearAllPoints()
            ppin:SetPoint("CENTER", canvas, "TOPLEFT", p.x * canvas:GetWidth(), -p.y * canvas:GetHeight())
            ppin:Show()
        else
            ppin:Hide()
        end
    end
    if type(WorldMapFrame.OnMapChanged) == "function" then
        hooksecurefunc(WorldMapFrame, "OnMapChanged", ns.RefreshMapPin)
    end
    WorldMapFrame:HookScript("OnShow", ns.RefreshMapPin)
    canvas:HookScript("OnSizeChanged", ns.RefreshMapPin)

    -- Klick auf die Karte setzt den Vorschlag.
    pick = CreateFrame("Button", nil, canvas)
    pick:SetAllPoints(canvas)
    pick:SetFrameLevel(canvas:GetFrameLevel() + 100)
    pick:RegisterForClicks("LeftButtonUp")
    pick:Hide()
    pick:SetScript("OnClick", function()
        pick:Hide()
        local x, y = WorldMapFrame.ScrollContainer:GetNormalizedCursorPosition()
        local mapID = WorldMapFrame:GetMapID()
        if mapID and x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            local info = C_Map.GetMapInfo(mapID)
            local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
            if info and info.mapType and info.mapType < zoneType then
                ns.Print("Please open a zone map, not a continent or world map.")
                return
            end
            ns.HomeSubmitProposal(mapID, x, y, info and info.name or "Fightclub")
        else
            ns.Print("Invalid position.")
        end
    end)
    WorldMapFrame:HookScript("OnHide", function() pick:Hide() end)

    local btn = CreateFrame("Button", nil, WorldMapFrame, "UIPanelButtonTemplate")
    btn:SetSize(160, 22)
    -- Rechts und etwas höher, damit die Koordinatenanzeige am unteren Kartenrand frei bleibt
    btn:SetPoint("BOTTOMRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", -8, 30)
    btn:SetFrameLevel(canvas:GetFrameLevel() + 120)
    btn:SetText("Propose Fightclub")
    btn:SetScript("OnClick", function() ns.StartPick() end)
end

function ns.StartPick()
    if not Eligible() then
        ns.Print("Only the Top 10 may propose a new Fightclub location.")
        return
    end
    if not pick then ns.Print("World map not available."); return end
    if not WorldMapFrame:IsShown() then ToggleWorldMap() end
    pick:Show()
    ns.Print("Click the map to propose the Fightclub location.")
end

local function SafeSetupMap()
    local ok, err = pcall(SetupMap)
    if not ok then ns.Print("World map pin not available: " .. tostring(err)) end
end

if WorldMapFrame then
    SafeSetupMap()
else
    ns.RegisterEvent("ADDON_LOADED", function(name)
        if name == "Blizzard_WorldMap" then SafeSetupMap() end
    end)
end

----------------------------------------------------------------- Minimap
-- Richtungssymbol am Minimap-Rand. Weltkoordinaten: x wächst nach Norden, y nach Westen.
-- Sichtbarer Durchmesser der Minimap in Yards je Zoomstufe 0..5 (Aussen/Innen).
local MM_OUTDOOR = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 }
local MM_INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }
local mm
local mmDisabled = true -- erst nach erfolgreichem SetupMinimap aktiv

local function UpdateMinimap()
    local c = ns.db and ns.EffectiveHome()
    local pmap = c and C_Map.GetBestMapForUnit("player")
    local ppos = pmap and C_Map.GetPlayerMapPosition(pmap, "player")
    if not ppos then mm:Hide() return end
    local pc, pw = C_Map.GetWorldPosFromMapPos(pmap, ppos)
    local hc, hw = C_Map.GetWorldPosFromMapPos(c.mapID, CreateVector2D(c.x, c.y))
    if not (pw and hw) or pc ~= hc then mm:Hide() return end

    local north, west = hw.x - pw.x, hw.y - pw.y
    local bearing = (math.atan2 or math.atan)(-west, north) -- im Uhrzeigersinn ab Norden
    if GetCVar("rotateMinimap") == "1" and GetPlayerFacing() then
        bearing = bearing + GetPlayerFacing()
    end
    -- Innerhalb der sichtbaren Minimap-Reichweite steht das Symbol an der echten Position (genau auf dem Ort: in der
    -- Mitte); erst ausserhalb klebt es als Richtungsanzeige am Rand. Die Reichweite hängt von Zoom und Innenraum ab.
    local diameters = IsIndoors and IsIndoors() and MM_INDOOR or MM_OUTDOOR
    local zoom = Minimap.GetZoom and Minimap:GetZoom() or 0
    local radiusYards = (diameters[zoom] or diameters[0]) / 2
    local dist = math.sqrt(north * north + west * west)
    local edge = Minimap:GetWidth() / 2 - 6
    local r = math.min(dist / radiusYards, 1) * edge
    if dist < 2 then r = 0 end -- praktisch auf dem Ort: kein Zittern durch wechselnde Richtung
    mm:ClearAllPoints()
    mm:SetPoint("CENTER", Minimap, "CENTER", math.sin(bearing) * r, math.cos(bearing) * r)
    mm:Show()
end

local acc = 0
local function SetupMinimap()
    mm = CreateFrame("Frame", nil, Minimap)
    mm:SetSize(20, 20)
    mm:SetFrameLevel(Minimap:GetFrameLevel() + 10)
    mm:Hide()
    local mmTex = mm:CreateTexture(nil, "OVERLAY")
    mmTex:SetAllPoints()
    mmTex:SetTexture(ICON)
    Minimap:HookScript("OnUpdate", function(_, elapsed)
        if mmDisabled then return end
        acc = acc + elapsed
        if acc >= 0.2 then
            acc = 0
            local ok, err = pcall(UpdateMinimap)
            if not ok then
                mmDisabled = true
                mm:Hide()
                ns.Print("Minimap arrow disabled: " .. tostring(err))
            end
        end
    end)
    mmDisabled = false
end

do
    local ok, err = pcall(SetupMinimap)
    if not ok then
        mmDisabled = true
        ns.Print("Minimap arrow disabled: " .. tostring(err))
    end
end

----------------------------------------------------------------- Tab im Leaderboard-Fenster
local function Remaining(p)
    local s = p.startTime + Home.DURATION - time()
    if s <= 0 then return "expired" end
    return ("%dh %02dm"):format(math.floor(s / 3600), math.floor(s % 3600 / 60))
end

function ns.HomeHideButtons()
    if ns.homeYes then ns.homeYes:Hide(); ns.homeNo:Hide() end
    if ns.homeLoc1 then ns.homeLoc1:Hide(); ns.homeLoc2:Hide() end
end

function ns.HomeRenderTab(f, header)
    if not ns.homeYes then
        ns.homeYes = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        ns.homeYes:SetSize(80, 22); ns.homeYes:SetPoint("BOTTOMLEFT", 12, 8); ns.homeYes:SetText("Yes")
        ns.homeYes:SetScript("OnClick", function() ns.HomeCastVote(true) end)
        ns.homeNo = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        ns.homeNo:SetSize(80, 22); ns.homeNo:SetPoint("LEFT", ns.homeYes, "RIGHT", 6, 0); ns.homeNo:SetText("No")
        ns.homeNo:SetScript("OnClick", function() ns.HomeCastVote(false) end)

        -- Klickbare Ortszeilen (Zeile 1 = aktueller Ort, Zeile 2 = Vorschlag): öffnet die Karte dort
        local function LocButton(row, which)
            local b = CreateFrame("Button", nil, f)
            b:SetPoint("TOPLEFT", row, "TOPLEFT", -2, 3)
            b:SetSize(f:GetWidth() - 28, 20)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.12)
            b:SetScript("OnClick", function()
                local loc
                if which == 1 then loc = ns.EffectiveHome() else loc = ns.db.home.proposal end
                if loc then ns.ShowLocationOnMap(loc) end
            end)
            b:Hide()
            return b
        end
        ns.homeLoc1 = LocButton(f.rows[1], 1)
        ns.homeLoc2 = LocButton(f.rows[2], 2)
    end
    header:SetText("Fightclub")

    local h, lines = ns.db.home, {}
    local c, p = h.current, h.proposal
    local eff = ns.EffectiveHome()
    if c then
        local cinfo = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(c.mapID)
        lines[#lines + 1] = ("Current: |cffffd100%s|r – %s (%.0f / %.0f) since %s"):format(
            c.name, cinfo and cinfo.name or "?", c.x * 100, c.y * 100, date("%d.%m. %H:%M", c.since))
    elseif eff then
        lines[#lines + 1] = ("Current: |cffffd100%s|r (default, no vote yet)"):format(eff.name)
    else
        lines[#lines + 1] = "Current: no Fightclub location chosen yet"
    end
    if p then
        local y, n = Home.Tally(p)
        local pinfo = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(p.mapID)
        lines[#lines + 1] = ("Vote: |cffffd100%s|r by %s – %s (%.0f / %.0f)"):format(
            p.name, p.proposer, pinfo and pinfo.name or "?", p.x * 100, p.y * 100)
        lines[#lines + 1] = ("Yes %d  /  No %d  (min. %d votes)"):format(y, n, Home.MIN_VOTES)
        lines[#lines + 1] = "Ends in " .. Remaining(p)
    else
        lines[#lines + 1] = "No vote open. To propose: open the map and click \"Propose Fightclub\"."
    end
    lines[#lines + 1] = "|cff80b0ffClick the location or vote line to open the map there.|r"
    local eligible = Eligible()
    lines[#lines + 1] = eligible and "|cff1eff00You may vote (Top 10).|r" or "|cffff4040Only the Top 10 may vote.|r"

    for i, row in ipairs(f.rows) do row:SetText(lines[i] or "") end

    local canVote = p and eligible and time() < p.startTime + Home.DURATION
    ns.homeYes:SetShown(true); ns.homeNo:SetShown(true)
    ns.homeLoc1:SetShown(eff ~= nil)
    ns.homeLoc2:SetShown(p ~= nil)
    ns.homeYes:SetEnabled(canVote and true or false)
    ns.homeNo:SetEnabled(canVote and true or false)
end

----------------------------------------------------------------- Befehle
function ns.RefreshHome()
    if ns.RefreshMapPin then ns.RefreshMapPin() end
    if ns.RefreshBoard then ns.RefreshBoard() end
end

-- Karte auf den Ort öffnen und einen Wegpunkt setzen.
function ns.ShowLocationOnMap(loc)
    -- Das Fenster würde die grosse Karte verdecken, deshalb schliessen (mit /fc wieder öffnen).
    if ns.HideBoard then ns.HideBoard() end
    pcall(function()
        if OpenWorldMap then OpenWorldMap(loc.mapID)
        elseif WorldMapFrame then ShowUIPanel(WorldMapFrame); WorldMapFrame:SetMapID(loc.mapID) end
    end)
    if C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(loc.mapID)
        and UiMapPoint and C_Map.SetUserWaypoint then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(loc.mapID, loc.x, loc.y))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
        ns.Print("Waypoint set.")
    end
end

ns.commands.proposal = function()
    local p = ns.db.home.proposal
    if not p then ns.Print("No vote open."); return end
    local info = C_Map.GetMapInfo(p.mapID)
    ns.Print(("Proposed: %s – %s (%.1f / %.1f) by %s"):format(p.name, info and info.name or "?", p.x * 100, p.y * 100, p.proposer))
    ns.ShowLocationOnMap(p)
end

ns.commands.home = function()
    local c, isDefault = ns.EffectiveHome()
    if not c then ns.Print("No Fightclub location chosen yet."); return end
    local info = C_Map.GetMapInfo(c.mapID)
    ns.Print(("Fightclub: %s – %s (%.1f / %.1f)%s"):format(c.name, info and info.name or "?", c.x * 100, c.y * 100,
        isDefault and " [default, no vote yet]" or ""))
    ns.ShowLocationOnMap(c)
end

ns.commands.vote = function(arg)
    arg = arg:lower()
    if arg == "ja" or arg == "yes" then ns.HomeCastVote(true)
    elseif arg == "nein" or arg == "no" then ns.HomeCastVote(false)
    else ns.Print("Usage: /fc vote yes|no") end
end

ns.commands.propose = function() ns.StartPick() end

-- /fc where: eigene Position messen (für die Standard-Orte in Home.DEFAULTS)
ns.commands.where = function()
    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then ns.Print("Position not available here."); return end
    local x, y = pos:GetXY()
    local info = C_Map.GetMapInfo(mapID)
    ns.Print(("%s: mapID %d, x %.4f, y %.4f  ->  { mapID = %d, x = %.3f, y = %.3f }"):format(
        info and info.name or "?", mapID, x, y, mapID, x, y))
end
