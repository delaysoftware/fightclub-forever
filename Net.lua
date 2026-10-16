local _, ns = ...
local Core = ns.NetCore

-- Einziger Sendeweg des Addons (WoW-Anbindung von NetCore.lua).
--  * Zwei Prefixe mit getrenntem Budget: FCd für direkte, dringende Nachrichten (Duelle, Beitritt), FCg für alles
--    andere (HELLO, Treffpunkt, Ausschluss, Gruppenliste). Gossip kann Duell-Bestätigungen so nicht mehr ausbremsen.
--  * Der Rückgabewert von SendAddonMessage wird ausgewertet: gedrosselte Nachrichten kommen zurück in die Schlange.
--  * Net.Reliable wiederholt eine Nachricht, bis der Empfänger sie bestätigt (Net.Done).
-- Der alte Prefix FIGHTCLUB wird weiterhin empfangen (Übergang von Version 0.7).
local Net = { URGENT = Core.URGENT, NORMAL = Core.NORMAL, BULK = Core.BULK }
ns.Net = Net

Net.DIRECT, Net.GOSSIP, Net.LEGACY = "FCd", "FCg", "FIGHTCLUB"
Net.CHANNEL = "FightclubNet"

local SendRaw = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local Register = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix

local queue = Core.NewQueue()
local reliable = Core.NewReliable()
local lastWhisper = {} -- [Name] = GetTime(): an wen wir zuletzt per Whisper gesendet haben

function Net.IsOurs(prefix)
    return prefix == Net.DIRECT or prefix == Net.GOSSIP or prefix == Net.LEGACY
end

for _, p in ipairs({ Net.DIRECT, Net.GOSSIP, Net.LEGACY }) do
    if Register then pcall(Register, p) end
end

-- Rückgabe von SendAddonMessage: nil/true (ältere Clients) oder Enum.SendAddonMessageResult.
local E = Enum and Enum.SendAddonMessageResult
local THROTTLED = {
    [E and E.AddonMessageThrottle or 3] = true,
    [E and E.ChannelThrottle or 8] = true,
}
local SUCCESS = E and E.Success or 0
-- Seit 12.0: Chat-Sperre (Encounter, gewertete PvP-Spiele u. Ä.) und "Ziel offline" bei Whispers.
local LOCKDOWN = E and E.AddOnMessageLockdown or 11
local OFFLINE = E and E.TargetOffline or 12
local offline = {} -- [Name] = GetTime(): Whisper-Ziel war zuletzt offline

local function DoSend(item)
    local ok, r = pcall(SendRaw, item.prefix, item.msg, item.chan, item.target)
    if not ok then return "fail" end
    if r == nil or r == true or r == SUCCESS then return "ok" end
    if r == false or THROTTLED[r] then return "throttle" end
    if r == LOCKDOWN then return "hold" end -- Sperre: Nachricht behalten und später erneut versuchen
    if r == OFFLINE and item.chan == "WHISPER" and item.target then
        offline[item.target] = GetTime()
    end
    return "fail"
end

-- true, wenn ein Whisper an name in den letzten 60 s als "offline" abgewiesen wurde.
function Net.IsOffline(name)
    local t = name and offline[name]
    return t ~= nil and GetTime() - t < 60
end

local function Pump()
    Core.Pump(queue, GetTime(), DoSend)
end

-- msg über chan (WHISPER/CHANNEL/GUILD/PARTY/RAID) senden. URGENT läuft über FCd, alles andere über FCg.
function Net.Send(msg, prio, chan, target)
    prio = prio or Net.NORMAL
    if chan == "WHISPER" and target then lastWhisper[target] = GetTime() end
    Core.Push(queue, {
        prefix = prio == Net.URGENT and Net.DIRECT or Net.GOSSIP,
        msg = msg, chan = chan, target = target, prio = prio,
    }, GetTime())
    Pump() -- sofort senden, wenn das Budget reicht
end

function Net.Whisper(target, msg, prio)
    Net.Send(msg, prio, "WHISPER", target)
end

function Net.ChannelId()
    local id = GetChannelName and GetChannelName(Net.CHANNEL)
    return (id and id > 0) and id or nil
end

-- Chat-Typ der aktuellen Gruppe: Instanzgruppen (Schlachtfeld, Dungeonfinder) brauchen INSTANCE_CHAT, sonst RAID/PARTY.
function Net.GroupChannel()
    local cat = LE_PARTY_CATEGORY_INSTANCE
    if cat and IsInGroup(cat) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- An alle: über den versteckten Kanal, sonst an Gilde und Gruppe/Raid.
function Net.Broadcast(msg, prio)
    local id = Net.ChannelId()
    if id then
        Net.Send(msg, prio, "CHANNEL", id)
        return
    end
    if IsInGuild() then Net.Send(msg, prio, "GUILD") end
    local grp = Net.GroupChannel()
    if grp then Net.Send(msg, prio, grp) end
end

-- Kurzformen für bestehenden Code
ns.Broadcast = function(msg) Net.Broadcast(msg, Net.NORMAL) end
ns.Send = function(msg, chan, target) Net.Send(msg, Net.NORMAL, chan, target) end

-- send(tries) wird sofort und dann nach NetCore.SCHEDULE wiederholt, bis Net.Done(key) oder ttl Sekunden um sind.
function Net.Reliable(key, send, ttl, onTimeout)
    Core.Track(reliable, key, { send = send, ttl = ttl, onTimeout = onTimeout }, GetTime())
end

function Net.Done(key) return Core.Done(reliable, key) end
function Net.IsPending(key) return reliable.list[key] ~= nil end
function Net.PendingCount(keyPrefix) return Core.Count(reliable, keyPrefix) end

function Net.Stats()
    local s = queue.stats
    return s.sent, s.throttled, s.dropped, s.failed, Core.Size(queue)
end

ns.RegisterEvent("PLAYER_LOGIN", function()
    C_Timer.NewTicker(0.1, Pump)
    C_Timer.NewTicker(0.25, function() Core.Tick(reliable, GetTime()) end)
end)

-- Whisper an Offline-Spieler erzeugen die Systemmeldung "No player named ... is currently playing". Für Namen, die wir
-- gerade selbst angeschrieben haben, blenden wir sie aus (sonst Spam bei Wiederholungen).
if ChatFrame_AddMessageEventFilter and type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" then
    local pat = "^" .. ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$"
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
        local name = type(msg) == "string" and msg:match(pat)
        local t = name and lastWhisper[name]
        if t and GetTime() - t < 10 then return true end
    end)
end
