local _, ns = ...

-- Rang-Abzeichen über Namensplaketten und am Zielrahmen, damit Fightclub-Mitglieder sofort auffallen.
-- Nameplate- und Frame-APIs sind im Forever-Client nicht verifiziert; alles läuft unter pcall.
-- Plaketten brauchen aktivierte Namensplaketten (Spieleinstellungen); /fc badges on|off schaltet um.

-- Liefert rating, distinct für eine Spieler-Unit, wenn sie ein (nicht ausgeschlossenes) Mitglied ist.
function ns.KeyForUnit(unit)
    if not (ns.db and unit and UnitExists(unit) and UnitIsPlayer(unit)) or UnitIsUnit(unit, "player") then return nil end
    for _, n in ipairs(ns.UnitNames(unit)) do
        local key = ns.ResolveMember(n)
        if key and not ns.IsBanned(key) then return key end
    end
end

function ns.MemberForUnit(unit)
    if ns.db then ns.RefreshCutoffs() end
    if not (ns.db and unit and UnitExists(unit) and UnitIsPlayer(unit)) then return nil end
    if UnitIsUnit(unit, "player") then
        return ns.db.me.rating, ns.Boost.DistinctWins(ns.db.history, ns.db.won)
    end
    local key = ns.KeyForUnit(unit)
    if key then
        local m = ns.db.members[key]
        return m.rating, m.distinct or 0
    end
end

-- true, wenn nur Text (ohne Symbole) angezeigt werden soll.
function ns.TextOnly()
    return ns.db and ns.db.settings and ns.db.settings.badgeStyle == "text"
end

local function Enabled()
    return ns.db and ns.db.settings and ns.db.settings.badges ~= false
end

local function LabelFor(unit)
    if not Enabled() then return nil end
    local rating, distinct = ns.MemberForUnit(unit)
    if not rating then return nil end
    return "FC " .. ns.RankLabel(rating, distinct, ns.TextOnly())
end

----------------------------------------------------------------- Namensplaketten
local plateBadges = {}

local function UpdatePlate(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end
    local label = LabelFor(unit)
    local badge = plateBadges[plate]
    if not label then
        if badge then badge:Hide() end
        return
    end
    if not badge then
        badge = plate:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        local anchor = plate.UnitFrame and plate.UnitFrame.name or plate.UnitFrame or plate
        badge:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
        plateBadges[plate] = badge
    end
    badge:SetText(label)
    badge:Show()
end

----------------------------------------------------------------- Zielrahmen
local targetBadge

-- Das Porträt eines Unit-Frames je nach Clientaufbau suchen.
local function FindPortrait(name, frame)
    if not frame then return nil end
    if _G[name .. "Portrait"] then return _G[name .. "Portrait"] end
    local c = frame[name .. "Container"]
    if c then
        if c.Portrait then return c.Portrait end
        if c.PlayerPortrait then return c.PlayerPortrait end
    end
    if frame.portrait then return frame.portrait end
    local content = frame[name .. "Content"]
    local main = content and content[name .. "ContentMain"]
    if main and main.Portrait then return main.Portrait end
end

-- Rang-Rahmen ums Porträt (Media\frame_<rang>.tga, 256x256 mit Alpha; das Loch in der Mitte misst 48 % der Bildbreite
-- und liegt genau mittig, so passt das Porträt bei jedem Rang gleich hinein):
--   alle:      Rahmen des Rangs (Rookie grau, Brawler Bronze, Fighter Silber, Champion Gold, Legend Rot mit Flügeln)
--   Brawler+:  Medaille mit Rang-Symbol (Media\rank_<rang>.tga) unten rechts am Porträt
--   Champion+: Rahmen pulsiert
local FRAME_DIR = "Interface\\AddOns\\Fightclub\\Media\\frame_"
local FRAME_NAMES = { "rookie", "brawler", "fighter", "champion", "legend" } -- nach ns.RankTier
local FRAME_SCALE = 2.0 -- Rahmenbreite im Verhältnis zum Porträt (Loch 48 % -> Loch etwas kleiner als das Porträt)
local decor = {}

local function Pulse(tex, fromAlpha, duration)
    local g = tex:CreateAnimationGroup()
    g:SetLooping("BOUNCE")
    local a = g:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(fromAlpha)
    a:SetDuration(duration)
    return g
end

-- Die Levelanzeige eines Unit-Frames suchen (je nach Clientaufbau unter verschiedenen Namen / Unterframes).
local function FindLevelText(name, frame)
    local direct = _G[name .. "LevelText"] or _G[name:gsub("Frame$", "") .. "LevelText"]
        or _G[name .. "TextureFrameLevelText"] or frame.LevelText
    if direct then return direct end
    local function Scan(f, depth)
        if depth > 3 or not f.GetChildren then return nil end
        for _, child in ipairs({ f:GetChildren() }) do
            if child.LevelText then return child.LevelText end
            local found = Scan(child, depth + 1)
            if found then return found end
        end
    end
    return Scan(frame, 1)
end

local function EnsureDecor(frame, portrait, frameName)
    if decor[frame] ~= nil then return decor[frame] or nil end
    decor[frame] = false
    if not portrait then return nil end
    local ok, d = pcall(function()
        local w = portrait:GetWidth()
        if not w or w < 20 then w = 58 end
        local d = { w = w }
        -- Porträt und Blizzard-Rahmen liegen in Unterframes, die über Texturen am Elternframe zeichnen. Deshalb
        -- brauchen wir eigene Ebenen: die Medaille ganz oben, der Rang-Rahmen knapp unter dem Level-Text (sonst
        -- verdeckt er die Levelanzeige). Ohne gefundenen Level-Text liegt der Rahmen unter allem.
        local base = frame:GetFrameLevel()
        local top = base
        local pf = portrait.GetParent and portrait:GetParent()
        if pf and pf.GetFrameLevel and pf:GetFrameLevel() > top then top = pf:GetFrameLevel() end
        local lt = FindLevelText(frameName, frame)
        local ltParent = lt and lt.GetParent and lt:GetParent()
        local ltLevel = ltParent and ltParent.GetFrameLevel and ltParent:GetFrameLevel()
        if ltLevel and ltLevel > top then top = ltLevel end

        local topHolder = CreateFrame("Frame", nil, frame)
        topHolder:SetAllPoints(frame)
        topHolder:SetFrameLevel(top + 20)
        if ltLevel then
            local ringHolder = CreateFrame("Frame", nil, frame)
            ringHolder:SetAllPoints(frame)
            ringHolder:SetFrameLevel(math.max(base + 1, ltLevel - 1))
            d.frame = ringHolder:CreateTexture(nil, "ARTWORK")
        else
            d.frame = frame:CreateTexture(nil, "OVERLAY", nil, 5)
        end
        d.frame:SetPoint("CENTER", portrait, "CENTER", 0, 0)
        d.frame:SetSize(w * FRAME_SCALE, w * FRAME_SCALE)
        -- Medaille: das Rang-Symbol ist selbst rund und hat seinen Rand, also ohne Maske und Untergrund
        d.medalIcon = topHolder:CreateTexture(nil, "OVERLAY", nil, 7)
        d.medalIcon:SetPoint("CENTER", portrait, "BOTTOMRIGHT", -w * 0.08, w * 0.08)
        d.medalIcon:SetSize(w * 0.62, w * 0.62)
        d.pulse = Pulse(d.frame, 0.55, 1.1)
        return d
    end)
    if ok then decor[frame] = d end
    return ok and d or nil
end

local function SetDecor(frameName, unit)
    local frame = _G[frameName]
    if not frame then return end
    local rating, distinct = ns.MemberForUnit(unit)
    local d = EnsureDecor(frame, FindPortrait(frameName, frame), frameName)
    if not d then return end
    local parts = { d.frame, d.medalIcon }
    if not (Enabled() and rating) then
        for _, t in ipairs(parts) do t:Hide() end
        d.pulse:Stop()
        return
    end
    local tier = ns.RankTier(rating, distinct)
    local rank = ns.GetRank(rating, distinct)
    d.frame:SetTexture(FRAME_DIR .. FRAME_NAMES[tier])
    d.frame:Show()

    local medal = tier >= 2 and not ns.TextOnly() and rank.icon
    d.medalIcon:SetShown(medal and true or false)
    if medal then d.medalIcon:SetTexture(rank.icon) end

    d.pulse:Stop()
    d.frame:SetAlpha(1)
    if tier >= 4 then d.pulse:Play() end
end

local function UpdateTarget()
    if not TargetFrame then return end
    pcall(SetDecor, "TargetFrame", "target")
    if not targetBadge then
        targetBadge = TargetFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        targetBadge:SetPoint("BOTTOMLEFT", TargetFrame, "TOPLEFT", 44, -14)
    end
    local label = LabelFor("target")
    targetBadge:SetText(label or "")
    targetBadge:SetShown(label ~= nil)
end

----------------------------------------------------------------- Aktualisierung
function ns.RefreshBadges()
    pcall(SetDecor, "PlayerFrame", "player")
    pcall(UpdateTarget)
    if C_NamePlate and C_NamePlate.GetNamePlates then
        local ok, plates = pcall(C_NamePlate.GetNamePlates)
        if ok and plates then
            for _, plate in ipairs(plates) do
                local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
                if unit then pcall(UpdatePlate, unit) end
            end
        end
    end
end

ns.RegisterEvent("NAME_PLATE_UNIT_ADDED", function(unit)
    pcall(UpdatePlate, unit)
end)

ns.RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(unit)
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if ok and plate and plateBadges[plate] then plateBadges[plate]:Hide() end
end)

ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    pcall(SetDecor, "PlayerFrame", "player")
end)

ns.RegisterEvent("PLAYER_TARGET_CHANGED", function()
    pcall(UpdateTarget)
end)

ns.commands.badges = function(arg)
    arg = (arg or ""):lower()
    ns.db.settings = ns.db.settings or {}
    if arg == "on" then ns.db.settings.badges = true
    elseif arg == "off" then ns.db.settings.badges = false
    elseif arg == "text" then ns.db.settings.badgeStyle = "text"
    elseif arg == "icon" then ns.db.settings.badgeStyle = "icon"
    else ns.Print("Usage: /fc badges on|off|icon|text (currently " .. (Enabled() and "on" or "off")
        .. ", style " .. (ns.TextOnly() and "text" or "icon") .. ")"); return end
    ns.Print("Rank badges", arg)
    ns.RefreshBadges()
end
