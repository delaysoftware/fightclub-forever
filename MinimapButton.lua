local _, ns = ...

-- Minimap-Symbol: Linksklick öffnet das Fenster, Rechtsklick zeigt den eigenen Stand, mit der Maus am Rand
-- verschiebbar. /fc minimap on|off. Alles unter pcall, damit ein fehlender Client-Baustein das Addon nicht stört.
local ICON = "Interface\\AddOns\\Fightclub\\Media\\icon"
local button

local function Settings()
    ns.db.settings = ns.db.settings or {}
    return ns.db.settings
end

local function Place()
    local angle = math.rad(Settings().minimapAngle or 220)
    local radius = (Minimap:GetWidth() / 2) + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function Drag()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local atan = math.atan2 or math.atan
    Settings().minimapAngle = math.deg(atan(cy / scale - my, cx / scale - mx))
    Place()
end

local function Create()
    button = CreateFrame("Button", "FightclubMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    -- Ohne Blizzards goldenen Ring: dunkle runde Scheibe als Untergrund (das Icon ist transparent) und das
    -- Wappen exakt in der Mitte des Knopfes.
    local back = button:CreateTexture(nil, "BACKGROUND")
    back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    back:SetSize(27, 27)
    back:SetPoint("CENTER")
    back:SetVertexColor(0.05, 0.05, 0.08, 0.9)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(29, 29)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.04, 0.96, 0.04, 0.96) -- den leeren Rand des Bildes abschneiden

    local hl = button:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    hl:SetBlendMode("ADD")
    hl:SetSize(31, 31)
    hl:SetPoint("CENTER")

    button:SetScript("OnClick", function(_, which)
        if which == "RightButton" then
            ns.commands.status()
        else
            ns.ToggleBoard()
        end
    end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", Drag)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Fightclub", 1, 0.82, 0)
        local me = ns.db.me
        local distinct = ns.Boost.DistinctWins(ns.db.history, ns.db.won)
        GameTooltip:AddLine(("%s – Rating %d"):format(ns.RankLabel(me.rating, distinct, ns.TextOnly()), me.rating), 1, 1, 1)
        GameTooltip:AddLine("Left-click: open window", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click: your status", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Drag: move around the minimap", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    Place()
end

local function Apply()
    if not button then Create() end
    button:SetShown(Settings().minimap ~= false)
end

ns.RegisterEvent("PLAYER_LOGIN", function()
    local ok, err = pcall(Apply)
    if not ok then ns.Print("Minimap button disabled:", tostring(err)) end
end)

ns.commands.minimap = function(arg)
    arg = (arg or ""):lower()
    if arg == "on" then Settings().minimap = true
    elseif arg == "off" then Settings().minimap = false
    else ns.Print("Usage: /fc minimap on|off"); return end
    local ok, err = pcall(Apply)
    if not ok then ns.Print("Minimap button error:", tostring(err)) end
end
