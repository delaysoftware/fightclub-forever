local _, ns = ...
local Home, Codec = ns.Home, ns.HomeCodec

local CHANNEL = "FightclubNet"
local STATE_INTERVAL = 600
local REASONS = {
    invalid = "invalid data",
    clock = "clock differs too much",
    expired = "proposal already expired",
    ["not eligible"] = "not eligible (Top 10 only)",
    cooldown = "cooldown after the last change is still running",
    duplicate = "proposal already exists",
    open = "an earlier vote is already running",
    ["no proposal"] = "no matching vote open",
    closed = "vote has ended",
}

-- Rate-Limit: max. 20 Nachrichten pro Absender und 10 s.
local seen = {}
local function Allowed(sender)
    local now = GetTime()
    local s = seen[sender]
    if not s or now - s.t > 10 then s = { t = now, n = 0 }; seen[sender] = s end
    s.n = s.n + 1
    return s.n <= 20
end

-- Eigene Aktionen (Vorschlag, Stimme) gehen mit normaler Priorität raus, Zustands-Gossip als BULK (ns.Net).
local Net = ns.Net
local function Broadcast(msg) Net.Broadcast(msg, Net.NORMAL) end

ns.Allowed = Allowed

local function Refresh()
    if ns.RefreshHome then ns.RefreshHome() end
end

function ns.HomeResolveNow()
    local r = Home.Resolve(ns.db.home, time())
    if r == "adopted" then
        ns.Print("New Fightclub location:", ns.db.home.current.name)
    elseif r == "rejected" then
        ns.Print("The Fightclub location vote was rejected.")
    end
    if r then Refresh() end
end

-- Wie viele Kopien einer Zustands-Nachricht pro Takt im ganzen Netz umlaufen sollen (bei grossen Netzen verbreitet
-- nur ein Teil der Clients den Zustand weiter; bis zu so vielen Mitgliedern jeder).
local RELAY_TARGET = 30

function ns.HomeBroadcastState()
    local h = ns.db.home
    if math.random() >= ns.Members.RelayChance(ns.db.members, RELAY_TARGET) then return end
    local function Q(msg) Net.Broadcast(msg, Net.BULK) end
    if h.current then Q(Codec.EncodeCurrent(h.current)) end
    if h.proposal then
        Q(Codec.EncodeProposal(h.proposal))
        for _, part in ipairs(Codec.EncodeVotes(h.proposal.id, h.proposal.votes, h.proposal.voteTimes)) do Q(part) end
    end
end

function ns.HomeSubmitProposal(mapID, x, y, name)
    local now = time()
    local p = { proposer = ns.DisplayName("player"), mapID = mapID, x = x, y = y, name = name, startTime = now }
    local ok, why = Home.Propose(ns.db.home, ns.BuildEntries(), p, now)
    if not ok then
        ns.Print("Proposal rejected:", REASONS[why] or why)
        return
    end
    ns.Print("New Fightclub location proposed:", ns.db.home.proposal.name, "(24 h)")
    Broadcast(Codec.EncodeProposal(ns.db.home.proposal))
    Refresh()
end

function ns.HomeCastVote(yes)
    local p = ns.db.home.proposal
    if not p then ns.Print("No vote open."); return end
    local ts = time()
    local ok, why = Home.Vote(ns.db.home, ns.BuildEntries(), ns.DisplayName("player"), p.id, yes, ts, ts)
    if not ok then ns.Print("Vote rejected:", REASONS[why] or why); return end
    Broadcast(Codec.EncodeVote(p.id, yes, ts))
    ns.Print("Vote cast:", yes and "Yes" or "No")
    Refresh()
end

-- Eingehende Nachrichten. Weitergeleitete (gossip) Vorschläge/Stimmen kommen von beliebigen
-- bekannten Mitgliedern; ihre Gültigkeit hängt nur an der Top-10-Prüfung der genannten Personen.
local function OnMessage(sender, text)
    if not ns.db.members[sender] or ns.IsBanned(sender) or not Allowed(sender) then return end
    local msg = Codec.Decode(text)
    if not msg then return end
    local state, entries, now = ns.db.home, ns.BuildEntries(), time()

    if msg.kind == "PROPOSE" then
        if sender ~= msg.p.proposer and not Home.IsEligible(entries, sender) then return end
        local hadId = state.proposal and state.proposal.id
        local ok = Home.Propose(state, entries, msg.p, now)
        if ok and (not hadId or hadId ~= state.proposal.id) then
            ns.Print("New Fightclub location vote:", state.proposal.name, "by", state.proposal.proposer)
        end
    elseif msg.kind == "VOTE" then
        Home.Vote(state, entries, sender, msg.id, msg.yes, now, msg.ts)
    elseif msg.kind == "VOTES" then
        -- Weitergeleitete Stimmen nur von Berechtigten; eigene Stimme ist lokal massgeblich.
        if not Home.IsEligible(entries, sender) then return end
        local me = ns.DisplayName("player")
        for voter, yes in pairs(msg.votes) do
            if voter ~= me then Home.Vote(state, entries, voter, msg.id, yes, now, msg.times[voter]) end
        end
    elseif msg.kind == "CUR" then
        if Home.MergeCurrent(state, msg.current, now) then
            ns.Print("Fightclub location updated:", msg.current.name)
        end
    end
    ns.HomeResolveNow()
    Refresh()
end

for _, kind in ipairs({ "PROPOSE", "VOTE", "VOTES", "CUR" }) do
    ns.msgHandlers[kind] = OnMessage
end

-- Dem Channel beitreten und die Meldungen aus den Chatfenstern ausblenden. Direkt beim Login
-- ist der Chat oft noch nicht bereit, deshalb mehrere Versuche.
local function HideChannel()
    if ChatFrame_RemoveChannel and DEFAULT_CHAT_FRAME then
        pcall(ChatFrame_RemoveChannel, DEFAULT_CHAT_FRAME, CHANNEL)
    end
end

local function InChannel()
    local id = GetChannelName(CHANNEL)
    return id and id > 0
end

function ns.JoinNet(silent)
    local was = InChannel()
    if not was then pcall(JoinChannelByName, CHANNEL) end
    C_Timer.After(2, function()
        HideChannel()
        if not was and InChannel() then -- frisch beigetreten: sofort melden, damit andere uns sehen
            ns.AnnounceHello()
            ns.HomeBroadcastState()
            if ns.BanBroadcastState then ns.BanBroadcastState() end
        end
        if not silent then
            ns.Print(InChannel() and ("Joined channel " .. CHANNEL .. " (hidden from chat).")
                or ("Could not join channel " .. CHANNEL .. " – using guild/group/whisper only."))
        end
    end)
end

ns.commands.join = function() ns.JoinNet(false) end

ns.RegisterEvent("PLAYER_LOGIN", function()
    for _, delay in ipairs({ 3, 8, 15, 30, 60 }) do
        C_Timer.After(delay, function() if not InChannel() then ns.JoinNet(true) end end)
    end
    C_Timer.After(10 + math.random(0, 50), function()
        HideChannel()
        ns.AnnounceHello()
        ns.HomeBroadcastState()
        local p = ns.db.home.proposal
        if p and Home.IsEligible(ns.BuildEntries(), ns.DisplayName("player")) then
            ns.Print("Fightclub location vote running:", p.name, "– /fc vote yes|no")
        end
        ns.HomeResolveNow()
    end)
    C_Timer.After(math.random(0, 120), function() C_Timer.NewTicker(STATE_INTERVAL, ns.HomeBroadcastState) end)
    C_Timer.NewTicker(60, ns.HomeResolveNow)
end)
