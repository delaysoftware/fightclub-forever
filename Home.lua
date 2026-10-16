local _, ns = ...

-- Reine Abstimmungslogik ohne WoW-API.
local Home = {}
ns.Home = Home

Home.DURATION = 24 * 3600
Home.COOLDOWN = 24 * 3600
Home.MIN_VOTES = 3
Home.TOP_N = 10
Home.MAX_CLOCK_SKEW = 300
Home.MAX_NAME = 16

-- Standard-Treffpunkt, solange keiner gewählt wurde (nur Anzeige, ändert nichts am Abstimmungszustand).
-- Koordinaten sind Schätzwerte "vor dem Stadttor"; mit /fc where genau messen und hier eintragen.
-- mapID 1411 = Durotar, 1429 = Elwynn Forest (Karten-IDs im Forever-Client unverifiziert).
Home.DEFAULTS = {
    Horde = { mapID = 1411, x = 0.457, y = 0.138, name = "Orgrimmar gate" },
    Alliance = { mapID = 1429, x = 0.325, y = 0.498, name = "Stormwind gate" },
}

local function Finite(v)
    return type(v) == "number" and v == v and v < math.huge and v > -math.huge -- schliesst nan und inf aus
end

local function InUnit(v)
    return Finite(v) and v >= 0 and v <= 1
end

local function Earlier(a, b)
    if a.startTime ~= b.startTime then return a.startTime < b.startTime end
    return a.id < b.id
end

-- Kürzt auf max Bytes, ohne ein UTF-8-Mehrbytezeichen zu zerschneiden.
function Home.TruncateUtf8(s, max)
    if #s <= max then return s end
    local cut = max
    while cut > 0 do
        local b = s:byte(cut + 1)
        if b and b >= 0x80 and b <= 0xBF then cut = cut - 1 else break end
    end
    return s:sub(1, cut)
end

function Home.IsEligible(entries, name)
    local sorted = {}
    for i, e in ipairs(entries) do sorted[i] = e end
    table.sort(sorted, function(a, b)
        if a.rating ~= b.rating then return a.rating > b.rating end
        return a.name < b.name
    end)
    for i = 1, math.min(Home.TOP_N, #sorted) do
        if sorted[i].name == name then return true end
    end
    return false
end

function Home.Tally(proposal)
    local yes, no = 0, 0
    for _, v in pairs(proposal.votes) do
        if v then yes = yes + 1 else no = no + 1 end
    end
    return yes, no
end

function Home.Propose(state, entries, p, now)
    if type(p) ~= "table" or type(p.proposer) ~= "string" or type(p.name) ~= "string" then
        return false, "invalid"
    end
    if not Finite(p.mapID) or not InUnit(p.x) or not InUnit(p.y)
        or not Finite(p.startTime) or p.startTime <= 0 then
        return false, "invalid"
    end
    if p.startTime > now + Home.MAX_CLOCK_SKEW then return false, "clock" end
    if now >= p.startTime + Home.DURATION then return false, "expired" end
    if not Home.IsEligible(entries, p.proposer) then return false, "not eligible" end
    if state.current and p.startTime - state.current.since < Home.COOLDOWN then
        return false, "cooldown"
    end

    local proposal = {
        id = p.proposer .. "-" .. p.startTime,
        proposer = p.proposer,
        mapID = p.mapID, x = p.x, y = p.y,
        name = Home.TruncateUtf8(p.name, Home.MAX_NAME),
        startTime = p.startTime,
        votes = { [p.proposer] = true },
        voteTimes = { [p.proposer] = p.startTime },
    }
    if state.proposal then
        if state.proposal.id == proposal.id then return false, "duplicate" end
        if not Earlier(proposal, state.proposal) then return false, "open" end
    end
    state.proposal = proposal
    return true
end

-- ts (optional, Standard now): Zeitpunkt der Stimmabgabe; die Stimme mit dem grössten ts gewinnt,
-- bei Gleichstand bleibt die bestehende.
function Home.Vote(state, entries, voter, id, yes, now, ts)
    local p = state.proposal
    if not p or p.id ~= id then return false, "no proposal" end
    if type(yes) ~= "boolean" then return false, "invalid" end
    ts = ts or now
    if not Finite(ts) then return false, "invalid" end
    if ts > now + Home.MAX_CLOCK_SKEW then return false, "clock" end
    if now >= p.startTime + Home.DURATION then return false, "closed" end
    if not Home.IsEligible(entries, voter) then return false, "not eligible" end
    p.voteTimes = p.voteTimes or {}
    local old = p.voteTimes[voter]
    if old and old >= ts then return true end
    p.votes[voter] = yes
    p.voteTimes[voter] = ts
    return true
end

function Home.Resolve(state, now)
    local p = state.proposal
    if not p or now < p.startTime + Home.DURATION then return nil end
    local yes, no = Home.Tally(p)
    state.proposal = nil
    if yes + no >= Home.MIN_VOTES and yes > no then
        state.current = {
            mapID = p.mapID, x = p.x, y = p.y, name = p.name,
            since = p.startTime + Home.DURATION,
            epoch = (state.current and state.current.epoch or 0) + 1,
        }
        return "adopted"
    end
    return "rejected"
end

local function CurKey(c)
    return ("%d:%.4f:%.4f:%s"):format(c.mapID, c.x, c.y, c.name)
end

-- Gleiche epoch: kleinere since gewinnt, dann der kleinere Schlüssel (Konvergenz unabhängig von der Reihenfolge).
local function TieWins(c, cur)
    if c.since ~= cur.since then return c.since < cur.since end
    return CurKey(c) < CurKey(cur)
end

function Home.MergeCurrent(state, c, now)
    if type(c) ~= "table" or not Finite(now) then return false end
    if not (Finite(c.epoch) and c.epoch >= 1 and Finite(c.mapID) and Finite(c.since)
        and InUnit(c.x) and InUnit(c.y) and type(c.name) == "string") then
        return false
    end
    if c.since > now + Home.MAX_CLOCK_SKEW then return false end
    local step = Home.COOLDOWN + Home.DURATION
    local cur = state.current
    local clean = {
        mapID = c.mapID, x = c.x, y = c.y,
        name = Home.TruncateUtf8(c.name, Home.MAX_NAME),
        since = c.since, epoch = c.epoch,
    }
    if cur then
        if c.epoch < cur.epoch then return false end
        if c.epoch == cur.epoch then
            if c.epoch > math.floor(c.since / step) + 1 then return false end
            if not TieWins(clean, cur) then return false end
        else
            if c.since < cur.since + step then return false end
            if c.epoch > cur.epoch + math.floor((c.since - cur.since) / step) then return false end
        end
    elseif c.epoch > math.floor(c.since / step) + 1 then
        return false
    end
    state.current = clean
    c = clean
    if state.proposal and state.proposal.startTime + Home.DURATION <= c.since then
        state.proposal = nil
    end
    return true
end
