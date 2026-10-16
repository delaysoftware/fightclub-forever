local _, ns = ...

-- Brawl-Direktvergleich: Das Addon zählt die ungewerteten Duelle pro Gegner (aus der Historie). Ein Reset setzt
-- diese Serie auf 0:0, wenn der andere zustimmt. Die Gesamt-Brawl-Bilanz (Brawl-Board) bleibt unberührt.
--   RESET|1|Q   Angebot, die Serie zurückzusetzen
--   RESET|1|Y   zugestimmt (gilt nur, wenn wir ein offenes Angebot an diesen Spieler haben)
--   RESET|1|N   abgelehnt
local PROTO = 1
local OFFER_TTL = 300
local outgoing, incoming = {}, {} -- [memberKey] = GetTime()

-- w, l der laufenden Serie gegen key.
function ns.BrawlSeries(key)
    local since = ns.db.h2h and ns.db.h2h[key]
    return ns.Boost.H2H(ns.db.history, key, since)
end

local function Refresh()
    if ns.RefreshBoard then ns.RefreshBoard() end
end

local function ResetSeries(key)
    ns.db.h2h = ns.db.h2h or {}
    ns.db.h2h[key] = time()
    Refresh()
end

local function Fresh(t)
    return t and (GetTime() - t) <= OFFER_TTL
end

function ns.OfferBrawlReset(key)
    if not key or not ns.IsMember(key) or ns.IsBanned(key) then
        ns.Print("Unknown Fightclub member.")
        return
    end
    local w, l = ns.BrawlSeries(key)
    if w + l == 0 then ns.Print("No Brawl record against", key, "to reset."); return end
    if outgoing[key] and GetTime() - outgoing[key] < 60 then ns.Print("Offer to", key, "already sent – wait a minute."); return end
    outgoing[key] = GetTime()
    ns.Net.Whisper(key, ("RESET|%d|Q"):format(PROTO), ns.Net.URGENT)
    ns.Print(("Reset offer sent to %s (current Brawl record %d:%d)."):format(key, w, l))
end

function ns.AcceptBrawlReset(key)
    if not Fresh(incoming[key]) then ns.Print("No open reset offer from", key or "anyone"); return end
    incoming[key] = nil
    ResetSeries(key)
    ns.Net.Whisper(key, ("RESET|%d|Y"):format(PROTO), ns.Net.URGENT)
    ns.Print("Brawl record against", key, "reset to 0:0.")
end

function ns.DeclineBrawlReset(key)
    if not Fresh(incoming[key]) then return end
    incoming[key] = nil
    ns.Net.Whisper(key, ("RESET|%d|N"):format(PROTO), ns.Net.URGENT)
    ns.Print("Reset offer from", key, "declined.")
end

-- Genau ein offenes Angebot -> das; sonst nach Namen suchen.
local function PickIncoming(nameText)
    if nameText and nameText ~= "" then
        local names = {}
        for k in pairs(incoming) do names[#names + 1] = k end
        return ns.MatchName(nameText, names)
    end
    local only, n = nil, 0
    for k, t in pairs(incoming) do
        if Fresh(t) then only, n = k, n + 1 end
    end
    if n == 1 then return only end
end

if StaticPopupDialogs then
    StaticPopupDialogs["FIGHTCLUB_BRAWL_RESET"] = {
        text = "%s offers to reset your Brawl record (%s). Accept?",
        button1 = ACCEPT or "Accept",
        button2 = DECLINE or "Decline",
        OnAccept = function(_, data) ns.AcceptBrawlReset(data) end,
        OnCancel = function(_, data, reason) if reason ~= "timeout" then ns.DeclineBrawlReset(data) end end,
        timeout = 120,
        whileDead = true,
        hideOnEscape = true,
    }
end

ns.msgHandlers.RESET = function(sender, text)
    local key = ns.ResolveMember(sender)
    if not key or ns.IsBanned(key) then return end
    local _, _, kind = strsplit("|", text)
    if kind == "Q" then
        local w, l = ns.BrawlSeries(key)
        if w + l == 0 then
            ns.Net.Whisper(key, ("RESET|%d|N"):format(PROTO), ns.Net.URGENT)
            return
        end
        incoming[key] = GetTime()
        ns.Print(("%s offers to reset your Brawl record (%d:%d). /fc accept or /fc decline"):format(key, w, l))
        if StaticPopup_Show then pcall(StaticPopup_Show, "FIGHTCLUB_BRAWL_RESET", key, w .. ":" .. l, key) end
    elseif kind == "Y" then
        if Fresh(outgoing[key]) then
            outgoing[key] = nil
            ResetSeries(key)
            ns.Print("Brawl record against", key, "reset to 0:0.")
        end
    elseif kind == "N" then
        if outgoing[key] then
            outgoing[key] = nil
            ns.Print(key, "declined the Brawl reset.")
        end
    end
end

ns.commands.brawlreset = function(rest)
    local names = {}
    for name in pairs(ns.db.members) do names[#names + 1] = name end
    local key
    if (rest or "") ~= "" then
        key = ns.MatchName(rest, names)
    elseif UnitExists("target") then
        key = ns.KeyForUnit("target")
    end
    if not key then ns.Print("Usage: /fc brawlreset <player>  (or select the player)"); return end
    ns.OfferBrawlReset(key)
end

ns.commands.accept = function(rest)
    local key = PickIncoming(rest)
    if key then ns.AcceptBrawlReset(key) else ns.Print("No (unique) open reset offer. Use /fc accept <player>.") end
end

ns.commands.decline = function(rest)
    local key = PickIncoming(rest)
    if key then ns.DeclineBrawlReset(key) else ns.Print("No (unique) open reset offer. Use /fc decline <player>.") end
end

-- /fc brawl [Name]: Serie gegen einen Spieler anzeigen.
ns.commands.brawl = function(rest)
    local names = {}
    for name in pairs(ns.db.members) do names[#names + 1] = name end
    local key = ((rest or "") ~= "" and ns.MatchName(rest, names)) or (UnitExists("target") and ns.KeyForUnit("target"))
    if not key then ns.Print("Usage: /fc brawl <player>  (or select the player)"); return end
    local w, l = ns.BrawlSeries(key)
    ns.Print(("Brawl record against %s: %d:%d"):format(key, w, l))
end
