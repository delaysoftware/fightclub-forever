local _, ns = ...

local ROWS = 18
local ROW_H = 22
local WIDTH = 580
local board

local function BareName(name)
    return (name or ""):match("^[^-]+") or ""
end

-- WoW Forever hat Vor- und Nachname. UnitName liefert evtl. nur den Vornamen, Addon-Nachrichten
-- tragen den vollen Namen. Alle bekannten Schreibweisen einer Unit sammeln.
function ns.UnitNames(unit)
    local out, seen = {}, {}
    local function add(n)
        n = BareName(n)
        if n ~= "" and not seen[n:lower()] then seen[n:lower()] = true; out[#out + 1] = n end
    end
    add(UnitName(unit))
    if UnitFullName then add((UnitFullName(unit))) end
    if GetUnitName then add(GetUnitName(unit, false)); add(GetUnitName(unit, true)) end
    return out
end

-- Anzeigename: die längste (= vollständigste) Schreibweise.
function ns.DisplayName(unit)
    local best = ""
    for _, n in ipairs(ns.UnitNames(unit)) do if #n > #best then best = n end end
    return best
end

-- True, wenn name der eigene Charakter ist. Ein Name, der mit meinem (evtl. nur Vor-)Namen
-- plus Leerzeichen beginnt, zählt ebenfalls (Vorname vs. "Vorname Nachname").
local selfNames -- eigene Namen in Kleinschreibung (gecacht: IsSelf läuft pro Mitglied und darf keine API-Aufrufe machen)
function ns.IsSelf(name)
    local n = BareName(name):lower()
    if n == "" then return false end
    if not selfNames or #selfNames == 0 then
        selfNames = {}
        for _, mine in ipairs(ns.UnitNames("player")) do selfNames[#selfNames + 1] = mine:lower() end
    end
    for i = 1, #selfNames do
        local m = selfNames[i]
        if n == m or n:sub(1, #m + 1) == m .. " " or m:sub(1, #n + 1) == n .. " " then return true end
    end
    return false
end
ns.RegisterEvent("PLAYER_ENTERING_WORLD", function() selfNames = nil end)

-- Eigene Daten + bekannte Mitglieder, nach Rating sortiert. Der eigene Charakter steht genau einmal drin.
-- Die Liste wird kurz zwischengespeichert (Sortieren von 1000+ Mitgliedern bei jeder Nachricht wäre zu teuer);
-- eigene Änderungen (Duell, Sperre, Charakterwechsel) rufen ns.InvalidateEntries() auf. Die Einträge sind
-- gemeinsam genutzt und dürfen nicht verändert werden.
local ENTRIES_TTL = 1.5
local entriesCache, entriesAt = nil, -1e9

function ns.InvalidateEntries() entriesCache = nil end

function ns.BuildEntries()
    local now = GetTime()
    if entriesCache and now - entriesAt < ENTRIES_TTL then return entriesCache end
    local me = ns.db.me
    local meEntry = { name = ns.DisplayName("player"), level = UnitLevel("player"), bw = me.bw or 0, bl = me.bl or 0,
        distinct = ns.Boost.DistinctWins(ns.db.history, ns.db.won), rating = me.rating, wins = me.wins, losses = me.losses, isMe = true }
    local list, cut = ns.Members.Build(ns.db.members, meEntry, ns.IsSelf, ns.IsBanned, time())
    ns.cutoffs = cut
    entriesCache, entriesAt = list, now
    return list
end

-- Prozentgrenzen aktuell halten (höchstens alle 5 s neu berechnen); für Stellen, die nur GetRank brauchen.
local lastCut = -1e9
function ns.RefreshCutoffs()
    local now = GetTime()
    if now - lastCut < 5 then return end
    lastCut = now
    ns.BuildEntries()
end

-- Favoriten: Mitgliedsschlüssel -> true, gespeichert in ns.db.settings.favorites.
-- Ein eingetippter Name darf kürzer sein als der volle Name ("Anna" passt auf "Anna Schmidt") und auch für
-- Spieler gelten, die das Addon noch nicht kennt.
local function FavEntry(key)
    local fav = ns.db.settings and ns.db.settings.favorites
    if not fav then return nil end
    if fav[key] then return key end
    local low = key:lower()
    for entry in pairs(fav) do
        local l = entry:lower()
        if low == l or low:sub(1, #l + 1) == l .. " " then return entry end
    end
end

function ns.IsFavorite(key)
    return FavEntry(key) ~= nil
end

-- Schaltet um und gibt zurück, ob der Spieler jetzt Favorit ist.
function ns.ToggleFavorite(key)
    ns.db.settings = ns.db.settings or {}
    ns.db.settings.favorites = ns.db.settings.favorites or {}
    local entry = FavEntry(key)
    if entry then ns.db.settings.favorites[entry] = nil else ns.db.settings.favorites[key] = true end
    if ns.RefreshBoard then ns.RefreshBoard(true) end
    return entry == nil
end

-- Namen eintragen (auch unbekannte Spieler). Gibt (ok, Meldung) zurück.
function ns.AddFavoriteByName(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return false, "Please type a player name." end
    local names = {}
    for name in pairs(ns.db.members) do names[#names + 1] = name end
    local key = ns.MatchName(text, names)
    key = key or text
    if ns.IsFavorite(key) then return false, key .. " is already a favorite." end
    ns.db.settings = ns.db.settings or {}
    ns.db.settings.favorites = ns.db.settings.favorites or {}
    ns.db.settings.favorites[key] = true
    if ns.RefreshBoard then ns.RefreshBoard(true) end
    return true, key .. " added to favorites."
end

-- Filtert die sortierte Liste; Positionen (e.pos) bleiben die globalen Plätze.
local function Filter(list, text, rankName, favOnly)
    text = (text or ""):lower()
    if text == "" and not rankName and not favOnly then return list end
    local out = {}
    for _, e in ipairs(list) do
        if (text == "" or e.name:lower():find(text, 1, true))
            and (not rankName or ns.GetRank(e.rating, e.distinct).name == rankName)
            and (not favOnly or (not e.isMe and ns.IsFavorite(e.name))) then
            out[#out + 1] = e
        end
    end
    return out
end

-- Spalten je Ansicht: { Titel, x, Breite, Ausrichtung }
local LAYOUT = {
    board = {
        { "#", 16, 26, "RIGHT" }, { "Rank", 46, 88, "LEFT" }, { "Name", 138, 170, "LEFT" },
        { "Lvl", 312, 34, "RIGHT" }, { "Rating", 352, 56, "RIGHT" }, { "W/L", 416, 64, "RIGHT" },
        { "Win%", 486, 56, "RIGHT" },
    },
    brawl = {
        { "#", 16, 26, "RIGHT" }, { "Name", 46, 236, "LEFT" }, { "Lvl", 288, 36, "RIGHT" },
        { "W/L", 332, 76, "RIGHT" }, { "Win%", 414, 50, "RIGHT" }, { "You vs.", 470, 72, "RIGHT" },
    },
    rivals = {
        { "Name", 16, 188, "LEFT" }, { "Ranked", 210, 58, "RIGHT" }, { "Win%", 274, 40, "RIGHT" },
        { "Brawl", 320, 58, "RIGHT" }, { "Win%", 384, 40, "RIGHT" }, { "Total", 428, 66, "RIGHT" },
        { "Last", 498, 44, "RIGHT" },
    },
    history = {
        { "Date", 16, 110, "LEFT" }, { "Type", 132, 60, "LEFT" }, { "Result", 198, 60, "LEFT" },
        { "Opponent", 264, 170, "LEFT" }, { "Lvl", 440, 102, "LEFT" },
    },
}
local NCOLS = 7

local function CreateBoard()
    local f = CreateFrame("Frame", "FightclubBoard", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIDTH, 194 + ROWS * ROW_H)
    local pos = ns.db.settings and ns.db.settings.pos
    if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER") end
    f:SetScale((ns.db.settings and ns.db.settings.scale) or 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.db.settings = ns.db.settings or {}
        ns.db.settings.pos = { point, relPoint, x, y }
    end)
    f:SetFrameStrata("HIGH")
    f:Hide()
    tinsert(UISpecialFrames, "FightclubBoard") -- Esc schliesst

    f.mode, f.offset, f.search, f.rankFilter = "board", 0, "", nil

    -- Tabs
    local TABS = {
        -- Zeile 1: dein Weg (Ranglisten, Duelle)
        { mode = "board", label = "Ranked", row = 1 },
        { mode = "brawl", label = "Brawl", row = 1 },
        { mode = "rivals", label = "Rivals", row = 1 },
        { mode = "history", label = "History", row = 1 },
        -- Zeile 2: der Club (Treffpunkt, Ausschluss) und Nachschlagen (Ränge, Regeln)
        { mode = "home", label = "Fightclub", row = 2 },
        { mode = "bans", label = "Bans", row = 2 },
        { mode = "ranks", label = "Ranks", row = 2 },
        { mode = "rules", label = "Rules", row = 2 },
    }
    -- Jede Zeile füllt die volle Breite: Knopfbreite = (Fensterbreite - Ränder - Lücken) / Anzahl
    local perRow = { 0, 0 }
    for _, t in ipairs(TABS) do perRow[t.row] = perRow[t.row] + 1 end
    local colInRow = { 0, 0 }
    local tabButtons = {}
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        local col = colInRow[t.row]
        colInRow[t.row] = col + 1
        local n = perRow[t.row]
        local gap = 2
        local w = math.floor((WIDTH - 28 - gap * (n - 1)) / n)
        b:SetSize(w, 22)
        b:SetPoint("TOPLEFT", 14 + col * (w + gap), -28 - (t.row - 1) * 24)
        b:SetText(t.label)
        b:SetScript("OnClick", function()
            f.mode, f.offset = t.mode, 0
            f:Refresh()
        end)
        tabButtons[i] = b
    end

    -- Suchfeld + Rang-Filter (nur im Leaderboard)
    local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", 16, -88)
    searchLabel:SetText("Search:")
    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetSize(200, 20)
    box:SetPoint("LEFT", searchLabel, "RIGHT", 10, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(24)
    box:SetScript("OnTextChanged", function(self)
        f.search, f.offset = self:GetText(), 0
        f:Refresh()
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local rankBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    rankBtn:SetSize(110, 22)
    rankBtn:SetPoint("TOPRIGHT", -14, -86)
    rankBtn:SetScript("OnClick", function()
        if f.mode == "rivals" then
            -- Sortierung der Rivalen: Duelle -> beste Quote -> schlechteste Quote -> zuletzt
            local order = { "duels", "best", "worst", "recent" }
            local idx = 1
            for i, o in ipairs(order) do if o == f.rivalSort then idx = i end end
            f.rivalSort = order[idx % #order + 1]
            f.offset = 0
            f:Refresh()
            return
        end
        -- All -> Rookie -> ... -> Legend -> All
        local idx = 0
        for i, r in ipairs(ns.RANKS) do if r.name == f.rankFilter then idx = i end end
        idx = idx + 1
        f.rankFilter = ns.RANKS[idx] and ns.RANKS[idx].name or nil
        f.offset = 0
        f:Refresh()
    end)

    local favBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    favBtn:SetSize(104, 22)
    favBtn:SetPoint("RIGHT", rankBtn, "LEFT", -6, 0)
    favBtn:SetScript("OnClick", function()
        f.favOnly = not f.favOnly
        f.offset = 0
        f:Refresh()
    end)

    -- Kopf- und Datenzeilen als Spalten
    local TOP = -114
    f.TOP, f.ROW_H = TOP, ROW_H
    f.cols = {}
    local head = {}
    for c = 1, NCOLS do
        head[c] = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    end
    for r = 1, ROWS do
        f.cols[r] = {}
        for c = 1, NCOLS do
            f.cols[r][c] = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        end
    end
    -- Volle Zeilen für den Fightclub-Tab (HomeRenderTab erwartet f.rows + header)
    local header = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", 16, TOP)
    f.rows = {}
    for r = 1, ROWS do
        local row = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row:SetPoint("TOPLEFT", 16, TOP - r * ROW_H)
        row:SetWidth(WIDTH - 32)
        row:SetWordWrap(false)
        row:SetJustifyH("LEFT")
        f.rows[r] = row
    end

    -- Regeln: scrollbarer Text
    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", 16, TOP + 6)
    scroll:SetSize(WIDTH - 40, ROWS * ROW_H - 4)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIDTH - 40, 10)
    scroll:SetScrollChild(content)
    local rulesText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rulesText:SetPoint("TOPLEFT")
    rulesText:SetWidth(WIDTH - 44)
    rulesText:SetJustifyH("LEFT")
    rulesText:SetJustifyV("TOP")
    scroll:Hide()

    -- Zebra-Streifen; die eigene Zeile ist goldfarben hinterlegt
    local shade = {}
    for r = 1, ROWS do
        local t = f:CreateTexture(nil, "BACKGROUND")
        t:SetPoint("TOPLEFT", 12, TOP - r * ROW_H + 4)
        t:SetSize(WIDTH - 24, ROW_H)
        t:Hide()
        shade[r] = t
    end

    -- Version unten rechts, damit sofort sichtbar ist, welcher Stand läuft
    local ver = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ver:SetPoint("BOTTOMRIGHT", -16, 14)
    ver:SetText("v" .. (ns.version or "?") .. " |cffff8000BETA|r")

    -- Favorit per Namen hinzufügen (unten, nur in Ranked/Brawl)
    local addLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addLabel:SetPoint("BOTTOMLEFT", 16, 40)
    addLabel:SetText("Add favorite:")
    local addBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    addBox:SetSize(180, 20)
    addBox:SetPoint("LEFT", addLabel, "RIGHT", 10, 0)
    addBox:SetAutoFocus(false)
    addBox:SetMaxLetters(30)
    local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 22)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 6, 0)
    addBtn:SetText("Add")
    local function DoAdd()
        local ok, msg = ns.AddFavoriteByName(addBox:GetText())
        ns.Print(msg)
        if ok then addBox:SetText("") end
        addBox:ClearFocus()
    end
    addBtn:SetScript("OnClick", DoAdd)
    addBox:SetScript("OnEnterPressed", DoAdd)
    addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Stern pro Zeile: Favorit an/aus (nur Textzeichen, damit keine Grafikdatei nötig ist)
    local starBtns, starNames = {}, {}
    for r = 1, ROWS do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(18, 18)
        b:SetPoint("TOPLEFT", 12, TOP - r * ROW_H + 2)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        b.text:SetPoint("CENTER", 0, -3)
        b:SetScript("OnClick", function() if starNames[r] then ns.ToggleFavorite(starNames[r]) end end)
        b:Hide()
        starBtns[r] = b
    end

    -- "Reset"-Knopf pro Brawl-Zeile (bietet dem Spieler einen Reset der gemeinsamen Serie an)
    local resetBtns, rowNames = {}, {}
    for r = 1, ROWS do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(48, 18)
        b:SetPoint("TOPLEFT", 16 + 496, TOP - r * ROW_H + 2)
        b:SetText("Reset")
        b:SetScript("OnClick", function() if rowNames[r] then ns.OfferBrawlReset(rowNames[r]) end end)
        b:Hide()
        resetBtns[r] = b
    end

    local footer2 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footer2:SetPoint("BOTTOMLEFT", 16, 32)
    footer2:SetWidth(WIDTH - 32)
    footer2:SetJustifyH("LEFT")

    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footer:SetPoint("BOTTOMLEFT", 16, 14)
    footer:SetWidth(WIDTH - 90)
    footer:SetJustifyH("LEFT")

    local function ApplyLayout(layout)
        if not layout then for r = 1, ROWS do shade[r]:Hide() end end
        for c = 1, NCOLS do
            local col = layout and layout[c]
            head[c]:SetShown(col ~= nil)
            if col then
                head[c]:ClearAllPoints()
                head[c]:SetPoint("TOPLEFT", 16 + col[2], TOP)
                head[c]:SetWidth(col[3]); head[c]:SetJustifyH(col[4]); head[c]:SetText(col[1])
            end
            for r = 1, ROWS do
                local fs = f.cols[r][c]
                fs:SetShown(col ~= nil)
                if col then
                    fs:ClearAllPoints()
                    fs:SetPoint("TOPLEFT", 16 + col[2], TOP - r * ROW_H)
                    fs:SetWidth(col[3]); fs:SetJustifyH(col[4])
                    fs:SetText("")
                end
            end
        end
    end

    local function SetRow(r, ...)
        if select("#", ...) == 0 then
            shade[r]:Hide()
        else
            local mine = false
            for c = 1, NCOLS do
                local v = select(c, ...)
                if type(v) == "string" and v:find("^|cffffd100") then mine = true end
            end
            if mine then shade[r]:SetColorTexture(1, 0.82, 0, 0.18)
            else shade[r]:SetColorTexture(1, 1, 1, r % 2 == 0 and 0.06 or 0) end
            shade[r]:Show()
        end
        for c = 1, NCOLS do f.cols[r][c]:SetText(tostring((select(c, ...)) or "")) end
    end

    local function Scrolled(total)
        local maxOffset = math.max(0, total - ROWS)
        f.offset = math.max(0, math.min(f.offset, maxOffset))
        f.scrollTotal = total
    end

    -- Scrollleiste rechts: erscheint nur, wenn es mehr zu sehen gibt als in das Fenster passt
    local bar = CreateFrame("Slider", nil, f)
    bar:SetOrientation("VERTICAL")
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", WIDTH - 14, TOP + 6)
    bar:SetSize(8, ROWS * ROW_H - 4)
    bar:SetValueStep(1)
    bar:EnableMouse(true)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.08)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 0.82, 0, 0.6)
    thumb:SetSize(8, 30)
    bar:SetThumbTexture(thumb)
    bar:Hide()
    local syncing = false

    local function IsTextPage() return f.mode == "rules" or f.mode == "ranks" end

    local function UpdateBar()
        local total, visible, value
        if IsTextPage() then
            total, visible, value = content:GetHeight(), scroll:GetHeight(), scroll:GetVerticalScroll()
        elseif f.scrollTotal then
            total, visible, value = f.scrollTotal, ROWS, f.offset
        end
        local range = total and math.max(0, total - visible) or 0
        if range <= 0 then bar:Hide(); return end
        syncing = true
        bar:SetMinMaxValues(0, range)
        bar:SetValue(value)
        syncing = false
        thumb:SetHeight(math.max(20, bar:GetHeight() * visible / total))
        bar:Show()
    end

    bar:SetScript("OnValueChanged", function(_, value)
        if syncing then return end
        if IsTextPage() then
            scroll:SetVerticalScroll(value)
        else
            f.offset = math.floor(value + 0.5)
            f:Refresh()
        end
    end)

    function f:Refresh()
        self.scrollTotal = nil
        for i, t in ipairs(TABS) do
            tabButtons[i]:SetEnabled(t.mode ~= self.mode) -- aktiver Tab ist ausgegraut
        end
        local isBoard = self.mode == "board"
        local searchable = isBoard or self.mode == "brawl" or self.mode == "history" or self.mode == "rivals"
        searchLabel:SetShown(searchable); box:SetShown(searchable)
        rankBtn:SetShown(isBoard or self.mode == "rivals")
        favBtn:SetShown(searchable)
        local listMode = isBoard or self.mode == "brawl"
        addLabel:SetShown(listMode); addBox:SetShown(listMode); addBtn:SetShown(listMode)
        favBtn:SetText(self.favOnly and "|cffffd100Favorites: on|r" or "Favorites: off")
        local textMode = self.mode == "home" or self.mode == "bans"
        header:SetShown(textMode)
        for _, row in ipairs(self.rows) do row:SetShown(textMode) end
        footer:SetText("")
        footer2:SetText("")
        for r = 1, ROWS do resetBtns[r]:Hide(); starBtns[r]:Hide() end
        if ns.BanHideWidgets then ns.BanHideWidgets() end
        for _, row in ipairs(self.rows) do row:SetWidth(WIDTH - 32) end
        local textPage = self.mode == "rules" or self.mode == "ranks"
        scroll:SetShown(textPage)
        if textPage and self.pageShown ~= self.mode then scroll:SetVerticalScroll(0) end
        self.pageShown = textPage and self.mode or nil

        if textPage then
            if ns.HomeHideButtons then ns.HomeHideButtons() end
            ApplyLayout(nil)
            if self.mode == "rules" then
                if self.TitleText then self.TitleText:SetText("Fightclub – Rules") end
                rulesText:SetText(ns.RulesText())
            else
                if self.TitleText then self.TitleText:SetText("Fightclub – Ranks") end
                ns.RefreshCutoffs()
                rulesText:SetText(ns.RanksText(ns.db.me.rating, ns.Boost.DistinctWins(ns.db.history, ns.db.won), ns.cutoffs))
            end
            content:SetHeight(rulesText:GetStringHeight() + 10)
            footer:SetText("Mouse wheel scrolls.")
            return
        end

        if self.mode == "home" then
            ApplyLayout(nil)
            if self.TitleText then self.TitleText:SetText("Fightclub – Location") end
            ns.HomeRenderTab(self, header)
            return
        end
        if self.mode == "bans" then
            if ns.HomeHideButtons then ns.HomeHideButtons() end
            ApplyLayout(nil)
            if self.TitleText then self.TitleText:SetText("Fightclub – Bans") end
            ns.BanRenderTab(self, header)
            return
        end
        if ns.HomeHideButtons then ns.HomeHideButtons() end

        if self.mode == "history" then
            if self.TitleText then self.TitleText:SetText("Fightclub – History") end
            ApplyLayout(LAYOUT.history)
            local h = ns.db.history
            -- Gefilterte Liste, neueste zuerst
            local text, shown = (self.search or ""):lower(), {}
            for k = #h, 1, -1 do
                local e = h[k]
                if (text == "" or e.opponent:lower():find(text, 1, true))
                    and (not self.favOnly or ns.IsFavorite(e.opponent)) then
                    shown[#shown + 1] = e
                end
            end
            Scrolled(#shown)
            for r = 1, ROWS do
                local e = shown[self.offset + r]
                if e then
                    local res = e.won and "|cff1eff00Win|r" or "|cffff4040Loss|r"
                    if e.pending then res = "|cffa0a0a0" .. (e.won and "Win?" or "Loss?") .. "|r" end
                    local lv = e.level and ("%d vs %s"):format(e.level, e.oppLevel or "?") or "-"
                    local kind = e.ranked == false and "|cffa0a0a0Brawl|r" or "Ranked"
                    SetRow(r, date("%d.%m. %H:%M", e.time), kind, res, e.opponent, lv)
                else
                    SetRow(r)
                end
            end
            -- Siegquoten: gesamt und gegen Favoriten, getrennt nach Ranked und Brawl
            local st = { R = { 0, 0, 0, 0 }, B = { 0, 0, 0, 0 } } -- {alle w, alle l, fav w, fav l}
            for _, e in ipairs(h) do
                if e.ranked == false or (e.weight == nil or e.weight > 0) then
                    local s = st[e.ranked == false and "B" or "R"]
                    local k = e.won and 1 or 2
                    s[k] = s[k] + 1
                    if ns.IsFavorite(e.opponent) then s[k + 2] = s[k + 2] + 1 end
                end
            end
            local function Quote(w, l)
                if w + l == 0 then return "-" end
                return ("%d-%d (%d%%)"):format(w, l, math.floor(w / (w + l) * 100 + 0.5))
            end
            footer2:SetText(("Ranked: all %s, favorites %s  |  Brawl: all %s, favorites %s"):format(
                Quote(st.R[1], st.R[2]), Quote(st.R[3], st.R[4]), Quote(st.B[1], st.B[2]), Quote(st.B[3], st.B[4])))
            footer:SetText(("%d of %d duels shown%s"):format(#shown, #h, self.favOnly and " (favorites only)" or ""))
            return
        end

        if self.mode == "rivals" then
            if self.TitleText then self.TitleText:SetText("Fightclub – Rivals") end
            ApplyLayout(LAYOUT.rivals)
            local SORTS = { duels = "Sort: Duels", best = "Sort: Best %", worst = "Sort: Worst %", recent = "Sort: Recent" }
            self.rivalSort = self.rivalSort or "duels"
            rankBtn:SetText(SORTS[self.rivalSort])
            local function Pct(w, l) return (w + l > 0) and (w / (w + l)) or nil end
            local function PctText(w, l)
                local p = Pct(w, l)
                if not p then return "-" end
                local color = p >= 0.55 and "|cff1eff00" or (p <= 0.45 and "|cffff4040" or "|cffffffff")
                return ("%s%d%%|r"):format(color, math.floor(p * 100 + 0.5))
            end
            local all, list = ns.Boost.Rivals(ns.db.history), {}
            local text = (self.search or ""):lower()
            for _, r in ipairs(all) do
                r.duels = r.rw + r.rl + r.bw + r.bl
                -- Brawl-Spalte = laufende Serie (seit dem letzten vereinbarten Reset)
                r.bw, r.bl = ns.BrawlSeries(r.name)
                r.tw, r.tl = r.rw + r.bw, r.rl + r.bl
                if r.duels > 0 and (text == "" or r.name:lower():find(text, 1, true))
                    and (not self.favOnly or ns.IsFavorite(r.name)) then
                    list[#list + 1] = r
                end
            end
            local sort = self.rivalSort
            table.sort(list, function(a, b)
                local an, bn = a.tw + a.tl, b.tw + b.tl
                if sort == "best" or sort == "worst" then
                    local pa, pb = (an > 0) and (a.tw / an) or 0, (bn > 0) and (b.tw / bn) or 0
                    if pa ~= pb then
                        if sort == "best" then return pa > pb end
                        return pa < pb
                    end
                elseif sort == "recent" then
                    if a.last ~= b.last then return a.last > b.last end
                end
                if an ~= bn then return an > bn end
                return a.name < b.name
            end)
            Scrolled(#list)
            for r = 1, ROWS do
                local e = list[self.offset + r]
                starNames[r], rowNames[r] = nil, nil
                if e then
                    starNames[r] = e.name
                    starBtns[r].text:SetText(ns.IsFavorite(e.name) and "|cffffd100*|r" or "|cff606060*|r")
                    starBtns[r]:Show()
                    if e.bw + e.bl > 0 then rowNames[r] = e.name; resetBtns[r]:Show() end -- Reset der Brawl-Serie anbieten
                    SetRow(r, e.name, ("%d-%d"):format(e.rw, e.rl), PctText(e.rw, e.rl),
                        ("%d-%d"):format(e.bw, e.bl), PctText(e.bw, e.bl), PctText(e.tw, e.tl) .. (" (%d)"):format(e.tw + e.tl),
                        date("%d.%m.", e.last))
                else
                    SetRow(r)
                end
            end
            footer:SetText(("%d opponents%s  |  Brawl = current series; Reset offers 0:0 to the player"):format(
                #list, self.favOnly and " (favorites only)" or ""))
            return
        end

        if self.mode == "brawl" then
            if self.TitleText then self.TitleText:SetText("Fightclub – Brawl (unranked)") end
            ApplyLayout(LAYOUT.brawl)
            local list = {}
            for _, e in ipairs(ns.BuildEntries()) do
                if (e.bw or 0) + (e.bl or 0) > 0 or e.isMe then list[#list + 1] = e end
            end
            table.sort(list, function(a, b)
                if a.bw ~= b.bw then return a.bw > b.bw end
                if a.bl ~= b.bl then return a.bl < b.bl end
                return a.name < b.name
            end)
            for i, e in ipairs(list) do e.bpos = i end
            local shownList = Filter(list, self.search, nil, self.favOnly)
            Scrolled(#shownList)
            for r = 1, ROWS do
                local e = shownList[self.offset + r]
                rowNames[r], starNames[r] = nil, nil
                if e then
                    if not e.isMe then
                        starNames[r] = e.name
                        starBtns[r].text:SetText(ns.IsFavorite(e.name) and "|cffffd100*|r" or "|cff606060*|r")
                        starBtns[r]:Show()
                    end
                    local total = e.bw + e.bl
                    SetRow(r, e.bpos, e.isMe and ("|cffffd100" .. e.name .. "|r") or e.name, e.level or "?",
                        ("%d/%d"):format(e.bw, e.bl),
                        total > 0 and ("%d%%"):format(math.floor(e.bw / total * 100 + 0.5)) or "-",
                        (function()
                            if e.isMe then return "-" end
                            local sw, sl = ns.BrawlSeries(e.name)
                            return (sw + sl > 0) and ("%d:%d"):format(sw, sl) or "-"
                        end)())
                else
                    SetRow(r)
                end
            end
            footer:SetText(("%d players  |  W/L = each player's own total  |  You vs. = your duels with them"):format(#list))
            return
        end

        if self.TitleText then self.TitleText:SetText("Fightclub – Ranked Leaderboard") end
        ApplyLayout(LAYOUT.board)
        local all = ns.BuildEntries()
        local list = Filter(all, self.search, self.rankFilter, self.favOnly)
        rankBtn:SetText(self.rankFilter and ("Rank: " .. self.rankFilter) or "Rank: All")
        Scrolled(#list)
        for r = 1, ROWS do
            local e = list[self.offset + r]
            starNames[r] = nil
            if e and not e.isMe then
                starNames[r] = e.name
                starBtns[r].text:SetText(ns.IsFavorite(e.name) and "|cffffd100*|r" or "|cff606060*|r")
                starBtns[r]:Show()
            end
            if e then
                local total = e.wins + e.losses
                local name = e.isMe and ("|cffffd100" .. e.name .. "|r") or e.name
                SetRow(r, e.pos, ns.RankLabel(e.rating, e.distinct, ns.TextOnly()), name, e.level or "?", e.rating,
                    ("%d/%d"):format(e.wins, e.losses),
                    total > 0 and ("%d%%"):format(math.floor(e.wins / total * 100 + 0.5)) or "-")
            else
                SetRow(r)
            end
        end
        local me
        for _, e in ipairs(all) do if e.isMe then me = e end end
        local shown = #list == 0 and "no matches"
            or ("%d-%d of %d"):format(self.offset + 1, math.min(self.offset + ROWS, #list), #list)
        footer:SetText(("%s  |  You: #%d of %d  |  mouse wheel scrolls"):format(shown, me.pos, #all))
    end

    -- Scrollleiste nach jedem Neuzeichnen nachführen
    local baseRefresh = f.Refresh
    function f:Refresh()
        baseRefresh(self)
        UpdateBar()
    end

    f:SetScript("OnMouseWheel", function(self, delta)
        if self.mode == "rules" or self.mode == "ranks" then
            local max = math.max(0, content:GetHeight() - scroll:GetHeight())
            scroll:SetVerticalScroll(math.max(0, math.min(max, scroll:GetVerticalScroll() - delta * 40)))
            UpdateBar()
            return
        end
        self.offset = self.offset - delta * 3
        self:Refresh()
    end)
    f:SetScript("OnShow", f.Refresh)
    return f
end

function ns.HideBoard()
    if board then board:Hide() end
end

function ns.ToggleBoard()
    board = board or CreateBoard()
    board:SetShown(not board:IsShown())
end

-- Netzwerk-Ereignisse können sich häufen (bei 1000 Mitgliedern mehrere pro Sekunde): Aktualisierungen bündeln.
-- immediate = true für Klicks des Spielers.
local refreshPending = false
function ns.RefreshBoard(immediate)
    local function Run()
        refreshPending = false
        if board and board:IsShown() then board:Refresh() end
        if ns.RefreshBadges then ns.RefreshBadges() end
    end
    if immediate then Run(); return end
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0.25, Run)
end

-- Rang im Unit-Tooltip anderer Mitglieder.
local function AddRankToTooltip(tooltip)
    if not (ns.db and tooltip.GetUnit) then return end
    local _, unit = tooltip:GetUnit()
    if not unit or not UnitIsPlayer(unit) then return end
    local rating, distinct = ns.MemberForUnit(unit)
    if not rating then return end
    local top = ns.TopPercent(rating)
    tooltip:AddLine(("Fightclub: %s (%d)%s"):format(ns.RankLabel(rating, distinct, ns.TextOnly()), rating,
        top and (" – Top " .. top .. "%") or ""))
    local key = ns.KeyForUnit(unit)
    if key then
        local sw, sl = ns.BrawlSeries(key)
        if sw + sl > 0 then tooltip:AddLine(("Brawls against you: %d:%d"):format(sl, sw)) end
    end
end

-- Unter pcall: scheitert der Hook im Client, dürfen die Befehle weiter unten trotzdem nicht fehlen.
local okHook, errHook = pcall(function()
    if TooltipDataProcessor and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, AddRankToTooltip)
    else
        GameTooltip:HookScript("OnTooltipSetUnit", AddRankToTooltip)
    end
end)
if not okHook then ns.tooltipError = tostring(errHook) end

-- Diagnose für Namensformate (Vor- und Nachname): /fc whoami [target]
ns.commands.whoami = function()
    local unit = UnitExists("target") and "target" or "player"
    ns.Print(unit, "->", table.concat(ns.UnitNames(unit), " | "), "(display: " .. ns.DisplayName(unit) .. ")")
end

ns.commands.scale = function(arg)
    local v = tonumber(arg)
    if not v or v < 0.7 or v > 1.5 then ns.Print("Usage: /fc scale 0.7-1.5"); return end
    ns.db.settings = ns.db.settings or {}
    ns.db.settings.scale = v
    if board then board:SetScale(v) end
    ns.Print("Window scale", v)
end

function ns.ShowTab(mode)
    board = board or CreateBoard()
    board.mode, board.offset = mode, 0
    board:Show()
    board:Refresh()
end

ns.commands.fav = function(rest)
    if (rest or "") ~= "" then
        local ok, msg = ns.AddFavoriteByName(rest)
        if not ok and msg:find("already", 1, true) then
            -- Zweiter Aufruf mit demselben Namen entfernt ihn wieder.
            local names = {}
            for name in pairs(ns.db.members) do names[#names + 1] = name end
            local key = ns.MatchName(rest, names) or rest
            ns.ToggleFavorite(key)
            msg = key .. " removed from favorites."
        end
        ns.Print(msg)
        return
    end
    local key = UnitExists("target") and ns.KeyForUnit("target")
    if not key then ns.Print("Usage: /fc fav <player>  (or select a known member) – adds or removes a favorite"); return end
    ns.Print(key, ns.ToggleFavorite(key) and "added to favorites." or "removed from favorites.")
end

ns.commands.favs = function()
    local list = {}
    for key in pairs(ns.db.settings and ns.db.settings.favorites or {}) do list[#list + 1] = key end
    table.sort(list)
    ns.Print("Favorites:", #list > 0 and table.concat(list, ", ") or "none (click the star in the list or /fc fav <player>)")
end
