local _, ns = ...

-- Protokoll (versioniert, Felder mit | getrennt):
--   HELLO|v|rating|wins|losses|level|distinct   Mitglied meldet sich (Login, Gruppe, Duell-Anfrage)
--   DUEL|v|R oder U              Duellmodus ankündigen (R = gewertet, U = ungewertet / Brawl)
--   RES|v|W oder L|R oder U|ts[|an]   Duell-Ergebnis aus Sicht des Senders
--   RACK|v|ts[|an]                    Empfangsbestätigung eines RES
-- Ein Duell zählt erst, wenn beide Seiten gegenteilige Ergebnisse melden. Gesendet wird über ns.Net (Net.lua).
local Net = ns.Net
local PROTO = 1
-- Ergebnisse warten bis zu WAIT Sekunden auf das Gegenstück (verzögerte Nachrichten); ob zwei zusammengehören,
-- entscheidet der Zeitstempel des Duellendes (siehe DuelParse.CanPair), nicht die Ankunftszeit.
local WAIT = 600
local UNKNOWN_WAIT = 120 -- Gegner war beim Duell unbekannt: so lange auf sein Ergebnis warten
local NOTICE_AFTER = 120
local function Stamp() return (GetServerTime and GetServerTime()) or time() end

ns.msgHandlers = {}

-- Diagnose für /fc debug: letzte Schritte der Ergebnis-Bestätigung.
ns.dbg = ns.dbg or { count = 0 }
ns.dbg.claims = {}
local function ClaimLog(text)
    local l = ns.dbg.claims
    l[#l + 1] = text
    if #l > 8 then table.remove(l, 1) end
end

local MODE_TTL = 600
local modes = { local_ = {}, remote = {} } -- [opponent] = { mode = "R"|"U", t }

-- Der Modus eines Duells gilt als ungewertet ("U"), wenn eine Seite das angekündigt hat.
local function ModeFor(opponent)
    for _, t in ipairs({ modes.local_, modes.remote }) do
        local m = t[opponent]
        if m and m.mode == "U" and (GetTime() - m.t) <= MODE_TTL then return "U" end
    end
    return "R"
end

-- Eigene Ankündigung (aus dem Rechtsklick-Menü) an den Gegner schicken und merken. Das HELLO dazu sorgt dafür, dass
-- der Gegner uns kennt, bevor das Duell endet.
function ns.AnnounceDuelMode(opponent, mode)
    modes.local_[opponent] = { mode = mode, t = GetTime() }
    ns.UrgentHello(opponent)
    Net.Whisper(opponent, ("DUEL|%d|%s"):format(PROTO, mode), Net.URGENT)
end

local lastRequest = {} -- .t = Zeitpunkt der letzten eingehenden Duellanfrage (DUEL_REQUESTED)

ns.msgHandlers.DUEL = function(sender, text)
    if not ns.IsMember(sender) or ns.IsBanned(sender) then return end
    local _, _, mode = strsplit("|", text)
    if mode ~= "R" and mode ~= "U" then return end
    modes.remote[sender] = { mode = mode, t = GetTime() }
    -- Kam die Ankündigung ohne Duellanfrage (oder lange danach), sofort melden; sonst meldet DUEL_REQUESTED den Modus
    if mode == "U" and not (lastRequest.t and GetTime() - lastRequest.t < 5) then
        ns.Print(sender, "proposes an unranked Fightclub duel (Brawl).")
    end
end

local localClaims = {}  -- [Gegner] = Liste von { won, t, ts, unranked }
local remoteClaims = {} -- [Gegner] = Liste von { won, t, ts, unranked }

-- prio: Standard BULK im Kanal, sonst NORMAL.
function ns.SendHello(channel, target, prio)
    local me = ns.db.me
    local msg = ("HELLO|%d|%d|%d|%d|%d|%d|%d|%d"):format(PROTO, me.rating, me.wins, me.losses,
        UnitLevel("player") or 0, ns.Boost.DistinctWins(ns.db.history, ns.db.won), me.bw or 0, me.bl or 0)
    Net.Send(msg, prio or (channel == "CHANNEL" and Net.BULK or Net.NORMAL), channel, target)
end

-- Dringendes HELLO an einen (künftigen) Duellgegner, höchstens alle 5 Sekunden pro Spieler.
local urgentHello = {}
function ns.UrgentHello(target)
    if not target or target == "" then return end
    if urgentHello[target] and GetTime() - urgentHello[target] < 5 then return end
    urgentHello[target] = GetTime()
    ns.SendHello("WHISPER", target, Net.URGENT)
end

-- Systemmeldungen nennen evtl. nur den Vornamen, Addon-Nachrichten den vollen Namen.
function ns.ResolveMember(name)
    return ns.Members.Resolve(ns.db.members, name)
end

-- Obergrenze für die Mitgliederliste: Favoriten und Duellpartner bleiben, sonst fliegen die am längsten nicht gesehenen.
function ns.EvictMembers()
    local keep = {}
    for _, e in ipairs(ns.db.history) do keep[e.opponent] = true end
    for key in pairs(ns.db.h2h or {}) do keep[key] = true end
    local removed = ns.Members.Evict(ns.db.members, function(key) return keep[key] or ns.IsFavorite(key) end)
    if removed > 0 and ns.InvalidateEntries then ns.InvalidateEntries() end
    return removed
end

local helloDone = {}
-- Antwort-HELLO an ein Mitglied: pro Spieler höchstens alle 10 Minuten (das Sendetempo regelt ns.Net).
function ns.QueueHello(target)
    if helloDone[target] and GetTime() - helloDone[target] < 600 then return end
    helloDone[target] = GetTime()
    ns.SendHello("WHISPER", target)
end

-- Eigenen Stand in den Kanal melden. In grossen Netzen nur die Spitze (Members.ShouldAnnounce); alle anderen bleiben
-- lokal (Gilde, Gruppe, Duellpartner, Begegnungen über Discovery.lua).
function ns.AnnounceHello()
    local cid = Net.ChannelId()
    if cid and ns.Members.ShouldAnnounce(ns.db.members, ns.db.me.rating) then ns.SendHello("CHANNEL", cid) end
end

local ANNOUNCE_EVERY = 1200
ns.RegisterEvent("PLAYER_LOGIN", function()
    C_Timer.NewTicker(2, function() ns.ResendResults() end)
    local function Loop()
        ns.AnnounceHello()
        C_Timer.After(ANNOUNCE_EVERY + math.random(0, 600), Loop)
    end
    C_Timer.After(ANNOUNCE_EVERY / 2 + math.random(0, 600), Loop)
    -- Mitglieder, die seit 60 Tagen nicht gesehen wurden, entfernen (hält die Datei klein)
    C_Timer.After(30, function()
        if ns.db then
            if ns.Members.Prune(ns.db.members, time(), 60 * 86400) > 0 and ns.InvalidateEntries then
                ns.InvalidateEntries()
            end
            if ns.Members.Count(ns.db.members) > ns.Members.CAP then ns.EvictMembers() end
        end
    end)
end)

function ns.IsMember(name)
    return ns.ResolveMember(name) ~= nil
end

-- Ergebnis-Abgleich zwischen zwei Spielern, ausfallsicher gebaut:
--  * Jede Seite sendet ihr Ergebnis (RES) mit dem Zeitstempel des Duellendes und wiederholt es, bis die Gegenseite den
--    Empfang bestätigt (RACK). Abwechselnd per Whisper und über den Kanal (mit Zieladresse), falls ein Weg Nachrichten verliert.
--  * Jede Seite bestätigt jedes empfangene RES, auch Wiederholungen. Wiederholungen werden nicht doppelt gezählt.
--  * Ergebnisse liegen in Listen pro Gegner (mehrere Duelle hintereinander gehen nicht verloren) und werden über den
--    Zeitstempel zugeordnet (DuelParse.CanPair), nicht über die Ankunftszeit.
--  * Gewertet wird erst, wenn beide Ergebnisse vorliegen und gegenteilig sind. Weil jede Seite ihr RES so lange sendet,
--    bis es bestätigt ist, kommen am Ende beide Seiten zum selben Stand (statt dass nur eine Seite das Duell zählt).
local seenRes = {}   -- ["Absender:ts"] = GetTime(): bereits verarbeitete Ergebnisse (gegen Doppelzählung)
local lastStamp = 0

-- Schlüssel der noch nicht bestätigten eigenen Ergebnisse in ns.Net.Reliable
local function ResKey(opponent, ts) return "res|" .. opponent .. "|" .. tostring(ts) end

local function AddClaim(tbl, opponent, claim)
    local l = tbl[opponent]
    if not l then l = {}; tbl[opponent] = l end
    l[#l + 1] = claim
end

-- onExpire(claim): wird für abgelaufene Einträge aufgerufen (eigene Ergebnisse ohne Bestätigung werden zurückgenommen).
local function Expire(list, onExpire, opponent)
    if not list then return end
    for i = #list, 1, -1 do
        if GetTime() - list[i].t > WAIT then
            local c = table.remove(list, i)
            if onExpire then onExpire(opponent, c) end
        end
    end
end

local function RevertUnconfirmed(opponent, claim)
    ClaimLog(("no confirmation for ts=%s from %s – reverting"):format(tostring(claim.ts), opponent))
    ns.RevertDuel(opponent, claim.ts)
end

-- Zwei zusammengehörende Ergebnisse auswerten.
-- Mein Ergebnis wurde bereits vorläufig verbucht (ClaimResult); jetzt bestätigen, zurücknehmen oder korrigieren.
local function Settle(opponent, mine, theirs)
    local ts = mine.ts
    if mine.won == theirs.won then
        ns.RevertDuel(opponent, ts, true)
        ns.Print("Result against", opponent, "conflicts – not counted.")
        return
    end
    modes.local_[opponent], modes.remote[opponent] = nil, nil
    local unranked = (mine.unranked or theirs.unranked) and true or false
    if unranked ~= (mine.unranked and true or false) then
        -- Der Gegner hat das Duell als Brawl gemeldet (oder umgekehrt): neu verbuchen
        ns.RevertDuel(opponent, ts, true)
        ns.CommitResult(opponent, mine.won, unranked, { ts = ts })
    elseif not ns.ConfirmDuel(opponent, ts) then
        ns.CommitResult(opponent, mine.won, unranked, { ts = ts }) -- kein vorläufiger Eintrag (mehr) da
    end
end

local function TryCommit(opponent)
    local mine, theirs = localClaims[opponent], remoteClaims[opponent]
    Expire(mine, RevertUnconfirmed, opponent); Expire(theirs)
    ClaimLog(("check %s: mine=%d theirs=%d"):format(opponent, mine and #mine or 0, theirs and #theirs or 0))
    if not (mine and theirs) then return end
    local progress = true
    while progress do
        progress = false
        for i, m in ipairs(mine) do
            local bestJ, bestD
            for j, r in ipairs(theirs) do
                if ns.DuelParse.CanPair(m, r) then
                    local d = (m.ts and r.ts) and math.abs(m.ts - r.ts) or math.abs(m.t - r.t)
                    if not bestD or d < bestD then bestJ, bestD = j, d end
                end
            end
            if bestJ then
                local r = table.remove(theirs, bestJ)
                table.remove(mine, i)
                Settle(opponent, m, r)
                progress = true
                break
            end
        end
    end
end

-- Eigenes Ergebnis senden und wiederholen (0.5 s, 1 s, 2 s, ...), bis der Gegner es mit RACK bestätigt. Die ersten
-- drei Versuche gehen per Whisper, danach abwechselnd auch über den Kanal mit Zieladresse – falls die Whisper-Adresse
-- im Client nicht passt (Vor- und Nachname im Forever-Client unverifiziert).
local function TrackRes(opponent, c, ttl)
    local msg = ("RES|%d|%s|%s|%d"):format(PROTO, c.won and "W" or "L", c.unranked and "U" or "R", c.ts)
    Net.Reliable(ResKey(opponent, c.ts), function(tries)
        local viaWhisper = tries <= 3 or tries % 2 == 0
        if Net.IsOffline(opponent) then viaWhisper = false end -- Whisper wurde als "offline" abgewiesen: Kanal nehmen
        if viaWhisper or not Net.ChannelId() then
            Net.Whisper(opponent, msg, Net.URGENT)
        else
            Net.Broadcast(msg .. "|" .. opponent, Net.URGENT)
        end
    end, ttl)
end

function ns.PendingResults()
    return Net.PendingCount("res|")
end

-- Läuft alle 2 Sekunden: alte Einträge aufräumen (das Wiederholen übernimmt ns.Net).
function ns.ResendResults()
    local now = GetTime()
    for key, t in pairs(seenRes) do
        if now - t > 3600 then seenRes[key] = nil end
    end
    for opponent in pairs(localClaims) do
        Expire(localClaims[opponent], RevertUnconfirmed, opponent)
    end
end

-- Ein Ergebnis gegen einen beim Duell noch unbekannten Gegner liegt unter dem Namen aus der Systemmeldung (evtl. nur
-- der Vorname). Meldet sich der Gegner mit vollem Namen, wird es dorthin umgehängt (und erneut gesendet).
local function Adopt(full)
    local found = {}
    for short in pairs(localClaims) do
        if short ~= full and full:sub(1, #short + 1) == short .. " " and not ns.db.members[short] then
            found[#found + 1] = short
        end
    end
    for _, short in ipairs(found) do
        local list = localClaims[short]
        localClaims[short] = nil
        for _, c in ipairs(list) do
            AddClaim(localClaims, full, c)
            if Net.Done(ResKey(short, c.ts)) then TrackRes(full, c, WAIT) end
        end
        ClaimLog("result against " .. short .. " assigned to " .. full)
    end
end

-- Mitgliedseintrag für einen Spieler anlegen, der uns direkt ein Ergebnis schickt (er hat also das Addon). Sein HELLO
-- liefert die echten Werte nach.
local function EnsureMember(name)
    if ns.db.members[name] then return end
    ns.db.members[name] = { rating = 1000, wins = 0, losses = 0, distinct = 0, bw = 0, bl = 0, lastSeen = time() }
    ns.Members.Touch()
    if ns.InvalidateEntries then ns.InvalidateEntries() end
    ns.QueueHello(name)
end

-- Von Duel.lua aufgerufen, sobald das eigene Ergebnis feststeht.
function ns.ClaimResult(opponent, won)
    opponent = ns.ResolveMember(opponent) or opponent
    if ns.IsBanned(opponent) then
        ns.Print("Duel against", opponent, "not counted (excluded from the Fightclub).")
        return
    end
    local known = ns.IsMember(opponent)
    local mode = ModeFor(opponent)
    local ts = Stamp()
    if ts <= lastStamp then ts = lastStamp + 1 end -- jede Meldung hat einen eigenen Stempel
    lastStamp = ts
    local claim = { won = won, t = GetTime(), ts = ts, unranked = (mode == "U") }
    AddClaim(localClaims, opponent, claim)
    ClaimLog(("sent RES %s mode=%s ts=%d%s"):format(won and "W" or "L", mode, ts, known and "" or " (unknown opponent)"))
    TrackRes(opponent, claim, known and WAIT or UNKNOWN_WAIT)
    if known then
        -- Sofort vorläufig verbuchen (Rückmeldung ohne Wartezeit); die Bestätigung des Gegners macht es endgültig,
        -- bleibt sie aus, wird es nach WAIT zurückgenommen.
        ns.CommitResult(opponent, won, claim.unranked, { ts = ts, provisional = true })
    else
        -- Unbekannt: nicht vorläufig verbuchen (ohne Addon käme nie eine Bestätigung). Kommt sein Ergebnis, wird das
        -- Duell direkt endgültig verbucht.
        ns.UrgentHello(opponent)
        ns.Print("Duel against", opponent, "– waiting for their confirmation (they need the addon).")
    end
    TryCommit(opponent)
    -- Zählt nur mit Bestätigung des Gegners (beide brauchen das Addon). Nach einer Weile klar melden, das Ergebnis
    -- wird aber weiter wiederholt und bleibt bis WAIT im Speicher.
    C_Timer.After(NOTICE_AFTER, function()
        if known and Net.IsPending(ResKey(opponent, ts)) then
            ns.Print("No confirmation from", opponent, "yet – I keep trying; unconfirmed duels are removed again after a few minutes (both players need the addon).")
        end
    end)
end

local function OnHello(sender, v, rating, wins, losses, level, distinct, bw, bl, dist)
    rating, wins, losses = tonumber(rating), tonumber(wins), tonumber(losses)
    if not (rating and wins and losses) then return end
    -- Plausibilitätsgrenzen gegen kaputte/gefälschte Daten.
    rating = math.max(0, math.min(5000, rating))
    if ns.IsSelf(sender) or ns.IsBanned(sender) then return end
    local lvl = tonumber(level)
    lvl = lvl and lvl >= 1 and math.min(lvl, 80) or nil
    local isNew = ns.db.members[sender] == nil
    ns.db.members[sender] = {
        rating = rating, wins = wins, losses = losses,
        distinct = math.max(0, math.min(1000, tonumber(distinct) or 0)),
        bw = math.max(0, math.min(100000, tonumber(bw) or 0)),
        bl = math.max(0, math.min(100000, tonumber(bl) or 0)),
        level = lvl, -- nil, wenn der Sender kein Level meldet (altes Protokoll)
        proto = tonumber(v), lastSeen = time(),
    }
    -- Auf Whisper-/neue Kontakte antworten, damit beide Seiten sich kennen.
    ClaimLog(("HELLO from %s via %s%s"):format(sender, tostring(dist), isNew and " (new)" or ""))
    if isNew then
        ns.Members.Touch()
        if ns.Members.Count(ns.db.members) > ns.Members.CAP then ns.EvictMembers() end
    end
    -- Wer uns direkt anschreibt, soll auch uns kennenlernen (sonst kennt A den B, aber B nicht A): antworten, auch
    -- wenn wir ihn schon kennen. QueueHello begrenzt das auf einmal pro 10 Minuten und Spieler.
    if isNew or dist == "WHISPER" then ns.QueueHello(sender) end
    -- Ein Duell, das wir vor dem Kennenlernen gemeldet hatten, dem vollen Namen zuordnen
    if isNew then Adopt(sender) end
    if ns.RefreshBoard then ns.RefreshBoard() end
end

-- Empfang eines Ergebnisses. to (nur bei Nachrichten über den Kanal): Zieladresse, andere ignorieren sie.
local function ForMe(to)
    return to == nil or to == "" or ns.IsSelf(to)
end

local function OnResult(sender, v, res, mode, ts, to, dist)
    if not ForMe(to) then return end
    sender = ns.ResolveMember(sender) or sender -- gleiche Schreibweise wie beim eigenen Claim
    if ns.IsBanned(sender) then return end
    if res ~= "W" and res ~= "L" then return end
    if not ns.IsMember(sender) then
        -- Wer uns ein Ergebnis schickt, hat das Addon: aufnehmen statt verwerfen (spart eine HELLO-Rundreise)
        ClaimLog("RES from unknown sender " .. tostring(sender) .. " – adding as member")
        EnsureMember(sender)
    end
    Adopt(sender)
    local tsn = tonumber(ts)
    ClaimLog(("got RES %s mode=%s ts=%s from %s"):format(tostring(res), tostring(mode), tostring(ts), sender))
    if tsn then
        -- Empfang immer bestätigen, auch bei Wiederholungen (die Bestätigung selbst kann verloren gehen). Auf demselben
        -- Weg antworten, auf dem das RES kam.
        local ack = ("RACK|%d|%d"):format(PROTO, tsn)
        if dist == "CHANNEL" then Net.Broadcast(ack .. "|" .. sender, Net.URGENT) else Net.Whisper(sender, ack, Net.URGENT) end
        local key = sender .. ":" .. tsn
        if seenRes[key] then return end -- schon verarbeitet: nicht doppelt zählen
        seenRes[key] = GetTime()
    end
    AddClaim(remoteClaims, sender, { won = (res == "W"), t = GetTime(), ts = tsn, unranked = (mode == "U") })
    TryCommit(sender)
end

-- Bestätigung: der Gegner hat unser Ergebnis mit diesem Stempel erhalten, Wiederholen beenden.
local function OnAck(sender, v, ts, to)
    if not ForMe(to) then return end
    sender = ns.ResolveMember(sender) or sender
    local tsn = tonumber(ts)
    if not tsn then return end
    if not Net.IsPending(ResKey(sender, tsn)) then Adopt(sender) end
    if Net.Done(ResKey(sender, tsn)) then
        ClaimLog(("ack for ts=%s from %s"):format(tostring(ts), sender))
    end
end

ns.RegisterEvent("CHAT_MSG_ADDON", function(prefix, text, dist, sender)
    if not Net.IsOurs(prefix) then return end
    -- Bei Chat-Sperre (12.0) können Text und Absender "Secret Values" sein: nicht auswertbar, also ignorieren.
    if issecretvalue and (issecretvalue(text) or issecretvalue(sender)) then return end
    ns.dbg = ns.dbg or { count = 0 }
    ns.dbg.count = ns.dbg.count + 1
    ns.dbg.last = tostring(sender) .. ": " .. tostring(text)
    sender = Ambiguate(sender, "none")
    if ns.IsSelf(sender) then return end
    local kind, v, a, b, c, d, e, g, h = strsplit("|", text)
    if kind == "HELLO" then OnHello(sender, v, a, b, c, d, e, g, h, dist)
    elseif kind == "RES" then OnResult(sender, v, a, b, c, d, dist)
    elseif kind == "RACK" then OnAck(sender, v, a, b)
    elseif ns.msgHandlers[kind] then ns.msgHandlers[kind](sender, text) end
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
    if IsInGuild() then ns.SendHello("GUILD") end
end)

ns.RegisterEvent("GROUP_ROSTER_UPDATE", function()
    local grp = Net.GroupChannel()
    if grp then ns.SendHello(grp) end
end)

-- Wer uns zum Duell fordert oder wen wir fordern, bekommt sofort ein HELLO: bis das Duell endet, kennen sich beide,
-- und die Ergebnisse lassen sich ohne weitere Rundreise paaren.
-- Zusätzlich sagen wir deutlich, ob die Anfrage gewertet oder ungewertet ist. Die Ankündigung (DUEL) des Gegners kommt
-- etwa gleichzeitig mit der Anfrage; deshalb kurz warten, bevor der Modus gemeldet wird.
local function AnnounceRequestMode(name)
    local key = ns.ResolveMember(name)
    if not key or ns.IsBanned(key) then return end -- normales Duell, kein Fightclub-Mitglied
    local unranked = ModeFor(key) == "U"
    local text = unranked and ("Unranked (Brawl) duel request from " .. key .. " – does not count for rating.")
        or ("Ranked duel request from " .. key .. " – counts for rating.")
    ns.Print(unranked and ("|cffff8000" .. text .. "|r") or ("|cff1eff00" .. text .. "|r"))
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, text, unranked and 1 or 0.1, unranked and 0.5 or 1, unranked and 0 or 0.1)
    end
end

ns.RegisterEvent("DUEL_REQUESTED", function(challenger)
    if not challenger then return end
    ns.UrgentHello(challenger)
    lastRequest.t = GetTime()
    C_Timer.After(1.2, function() pcall(AnnounceRequestMode, challenger) end)
end)

if hooksecurefunc and StartDuel then
    pcall(hooksecurefunc, "StartDuel", function(unit)
        if type(unit) ~= "string" then return end
        local name = unit
        if UnitExists and UnitExists(unit) and UnitIsPlayer(unit) and ns.DisplayName then name = ns.DisplayName(unit) end
        ns.UrgentHello(name)
    end)
end
