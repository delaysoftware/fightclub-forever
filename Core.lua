local addonName, ns = ...

ns.name = addonName
ns.DB_VERSION = 1

-- Zufall für zeitliche Streuung der Sendezeitpunkte (sonst melden sich nach einem Serverneustart alle gleichzeitig)
-- (math.randomseed gibt es nicht in jedem Client; WoW seedet math.random selbst, deshalb nur versuchen)
if math.randomseed then
    pcall(math.randomseed, (time and time() or 0) + math.floor((GetTime and GetTime() or 0) * 1000))
end

local defaults = {
    version = ns.DB_VERSION,
    chars = {}, -- pro Charakter: [Name-Realm] = { me, history, h2h } (siehe CharData.lua)
    members = {}, -- [name] = { rating, wins, losses, lastSeen }
    home = {}, -- { current = {...}, proposal = {...} }
    bans = {}, -- siehe Ban.lua
    settings = { badges = true },
}

function ns.Print(...)
    print("|cffff4040Fightclub|r:", ...)
end

-- Auf den aktuellen Charakter umschalten: Statistiken (me, history, h2h) sind pro Charakter getrennt.
function ns.BindCharacter()
    local realm = GetRealmName and GetRealmName() or ""
    local key = (UnitName("player") or "?") .. (realm ~= "" and ("-" .. realm) or "")
    local db = FightclubDB
    local foundLegacy = ns.CharData.MigrateLegacy(db)
    ns.charKey = key
    if ns.InvalidateEntries then ns.InvalidateEntries() end
    local ch = ns.CharData.Get(db, key)
    ns.CharData.TrimHistory(ch.history)
    ns.db = ns.CharData.Overlay(db, ch)
    return foundLegacy
end

local function InitDB()
    FightclubDB = FightclubDB or {}
    for k, v in pairs(defaults) do
        if FightclubDB[k] == nil then
            FightclubDB[k] = CopyTable and type(v) == "table" and CopyTable(v) or v
        end
    end
    -- Schema-Migrationen hier einhängen, wenn ns.DB_VERSION steigt.
    FightclubDB.version = ns.DB_VERSION
    ns.BindCharacter()
end

local frame = CreateFrame("Frame")
ns.frame = frame
ns.handlers = {}

function ns.RegisterEvent(event, fn)
    local list = ns.handlers[event]
    if not list then
        list = {}
        ns.handlers[event] = list
        frame:RegisterEvent(event)
    end
    list[#list + 1] = fn
end

-- Jeder Handler läuft einzeln unter pcall: ein Fehler in einem (z. B. in der Anzeige) darf die anderen
-- (z. B. die Duell-Erkennung) nicht blockieren. Fehler werden einmalig gemeldet und in /fc debug aufgeführt.
ns.errors = {}
local seenErrors = {}
frame:SetScript("OnEvent", function(_, event, ...)
    local list = ns.handlers[event]
    if list then
        for i = 1, #list do
            local ok, err = pcall(list[i], ...)
            if not ok then
                local msg = event .. ": " .. tostring(err)
                if not seenErrors[msg] then
                    seenErrors[msg] = true
                    ns.errors[#ns.errors + 1] = msg
                    if #ns.errors > 8 then table.remove(ns.errors, 1) end
                    print("|cffff4040Fightclub error|r", msg)
                end
            end
        end
    end
end)

ns.RegisterEvent("ADDON_LOADED", function(name)
    if name ~= addonName then return end
    InitDB()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local ok, version = pcall(getMeta, addonName, "Version")
    ns.version = ok and version or "?"
    ns.Print("v" .. ns.version .. " |cffff8000BETA|r loaded. Type /fc to open the leaderboard. Stats and ranks may be reset during the beta.")
    if FightclubDB.legacy then
        ns.Print("Stats from before the per-character update exist. Log in as the character that fought them and type /fc claim (or /fc claim discard).")
    end
end)

-- Falls der Charaktername beim Laden noch nicht bekannt war, beim Login neu zuordnen.
ns.RegisterEvent("PLAYER_LOGIN", function()
    local realm = GetRealmName and GetRealmName() or ""
    local key = (UnitName("player") or "?") .. (realm ~= "" and ("-" .. realm) or "")
    if FightclubDB and key ~= ns.charKey then ns.BindCharacter() end
end)

SLASH_FIGHTCLUB1 = "/fightclub"
SLASH_FIGHTCLUB2 = "/fc"
ns.commands = {
    claim = function(arg)
        arg = (arg or ""):lower()
        if arg == "discard" then
            FightclubDB.legacy = nil
            ns.Print("Old stats discarded.")
            return
        end
        local ok, why = ns.CharData.Claim(FightclubDB, ns.charKey, arg == "force")
        if ok then
            ns.BindCharacter()
            if ns.RefreshBoard then ns.RefreshBoard(true) end
            ns.Print("Old stats assigned to", ns.charKey)
        elseif why == "none" then
            ns.Print("No old stats to claim.")
        else
            ns.Print("This character already has stats. Use /fc claim force to overwrite them with the old stats.")
        end
    end,
    -- Alles zurücksetzen (nur dieser Client): Statistik, Historie, Mitglieder, Favoriten, Abstimmungen, Einstellungen.
    reset = function(arg)
        if (arg or ""):lower() ~= "confirm" then
            ns.Print("|cffff4040This deletes ALL Fightclub data on this computer|r (rating, history, members, favorites, votes, settings).")
            ns.Print("Type |cffffd100/fc reset confirm|r to continue.")
            return
        end
        for k in pairs(FightclubDB) do FightclubDB[k] = nil end
        ReloadUI() -- beim Neuladen legt das Addon eine leere Datenbank an
    end,
    status = function()
        local me = ns.db.me
        ns.Print(("Rating %d (%s) – %dW / %dL, wins against %d different opponents"):format(me.rating, ns.GetRank(me.rating, ns.Boost.DistinctWins(ns.db.history, ns.db.won)).name, me.wins, me.losses, ns.Boost.DistinctWins(ns.db.history, ns.db.won)))
    end,
    [""] = function()
        if ns.ToggleBoard then ns.ToggleBoard() end
    end,
}

SlashCmdList.FIGHTCLUB = function(arg)
    local cmd, rest = (arg or ""):match("^(%S*)%s*(.-)$")
    local fn = ns.commands[cmd:lower()]
    if fn then fn(rest) else ns.Print("Unknown command. /fc, /fc status, /fc claim, /fc home, /fc vote yes|no, /fc propose, /fc report, /fc ban, /fc bans, /fc duel, /fc badges, /fc scale, /fc hello, /fc debug, /fc join, /fc brawl, /fc brawlreset, /fc fav, /fc favs, /fc minimap, /fc where, /fc proposal, /fc reset") end
end
