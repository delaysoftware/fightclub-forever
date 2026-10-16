local _, ns = ...

-- Mitglieder finden, ohne dass man in derselben Gruppe oder Gilde sein muss:
--  * Anvisieren, Mouseover und Namensplaketten schicken einem unbekannten Spieler leise ein HELLO.
--    Hat er das Addon, antwortet er, und beide kennen sich. Ohne Addon passiert nichts Sichtbares.
--  * /fc hello [name]  schickt von Hand ein HELLO,  /fc debug  zeigt den Verbindungsstand.
-- Die Whisper-Zieladresse für Namen mit Vor- und Nachname ist im Forever-Client nicht verifiziert.

local PROBE_INTERVAL = 600 -- pro Spieler höchstens alle 10 Minuten
local GLOBAL_GAP = 2       -- insgesamt höchstens ein HELLO alle 2 Sekunden
local probed, lastSend = {}, -GLOBAL_GAP

local function Probe(unit)
    if not (ns.db and unit and UnitExists(unit) and UnitIsPlayer(unit)) then return end
    if UnitIsUnit(unit, "player") or not UnitIsFriend("player", unit) then return end
    local name = ns.DisplayName(unit)
    if name == "" or ns.ResolveMember(name) or ns.IsBanned(name) then return end
    local now = GetTime()
    if (probed[name] and now - probed[name] < PROBE_INTERVAL) or now - lastSend < GLOBAL_GAP then return end
    probed[name], lastSend = now, now
    ns.SendHello("WHISPER", name, ns.Net.BULK)
end

ns.RegisterEvent("PLAYER_TARGET_CHANGED", function() pcall(Probe, "target") end)
ns.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() pcall(Probe, "mouseover") end)
ns.RegisterEvent("NAME_PLATE_UNIT_ADDED", function(unit) pcall(Probe, unit) end)

ns.commands.hello = function(arg)
    local name = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        if not (UnitExists("target") and UnitIsPlayer("target")) then
            ns.Print("Usage: /fc hello <player>  (or select a player)")
            return
        end
        name = ns.DisplayName("target")
    end
    ns.SendHello("WHISPER", name)
    ns.Print("HELLO sent to", name .. ". If they have the addon, they appear in the list within a few seconds.")
end

ns.commands.debug = function()
    local cid = GetChannelName and GetChannelName("FightclubNet")
    ns.Print("my names:", table.concat(ns.UnitNames("player"), " | "))
    ns.Print("channel FightclubNet:", tostring(cid), "| guild:", tostring(IsInGuild()), "| group:", tostring(IsInGroup()))
    local n, names = 0, {}
    for name in pairs(ns.db.members) do
        n = n + 1
        if n <= 10 then names[#names + 1] = name end
    end
    ns.Print("known members:", n, #names > 0 and ("(" .. table.concat(names, ", ") .. ")") or "")
    for _, e in ipairs(ns.errors or {}) do ns.Print("error:", e) end
    ns.Print("version:", ns.version or "?", "| character:", ns.charKey or "?", "| history:", #ns.db.history,
        "| rating:", ns.db.me.rating)
    if ns.tooltipError then ns.Print("tooltip hook failed:", ns.tooltipError) end
    ns.Print("unconfirmed results being resent:", ns.PendingResults and ns.PendingResults() or 0)
    local sent, throttled, dropped, failed, queued = ns.Net.Stats()
    ns.Print(("messages: sent %d | throttled by client %d | dropped %d | failed %d | queued %d"):format(
        sent, throttled, dropped, failed, queued))
    local d = ns.dbg or {}
    ns.Print("addon messages received:", d.count or 0)
    if d.last then ns.Print("last:", d.last) end
    ns.Print("duel formats: KNOCKOUT =", tostring(DUEL_WINNER_KNOCKOUT), "| RETREAT =", tostring(DUEL_WINNER_RETREAT))
    for _, line in ipairs(d.claims or {}) do ns.Print("claim log:", line) end
    for _, line in ipairs(d.duel or {}) do ns.Print("duel log:", line) end
end
