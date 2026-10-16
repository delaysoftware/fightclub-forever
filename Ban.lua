local _, ns = ...

-- Reine Logik für Ausschluss-Abstimmungen (Cheater), ohne WoW-API.
-- state = { cases = {[target]=case}, banned = {[name]={since,untilT}}, cool = {[target]=untilT},
--           lastReport = {[reporter]=ts}, pending = {["target|since"]={[announcer]=true}} }
-- case  = { id, kind = "ban"|"lift", reporter, target, reason, startTime, votes, voteTimes }
local Ban = {}
ns.Ban = Ban

Ban.DURATION = 24 * 3600
Ban.MIN_VOTES = 5
Ban.MIN_VOTERS = 5              -- so viele Stimmberechtigte müssen existieren, sonst kein Antrag
Ban.MIN_DISTINCT = 3            -- Stimmrecht: Siege gegen mind. so viele verschiedene Gegner
Ban.BAN_TIME = 30 * 24 * 3600
Ban.REJECT_COOLDOWN = 7 * 24 * 3600
Ban.REPORT_COOLDOWN = 24 * 3600
Ban.MAX_CLOCK_SKEW = 300
Ban.MAX_REASON = 40

local function Finite(v)
    return type(v) == "number" and v == v and v < math.huge and v > -math.huge
end

local function Earlier(a, b)
    if a.startTime ~= b.startTime then return a.startTime < b.startTime end
    return a.id < b.id
end

function Ban.Ensure(state)
    state.cases = state.cases or {}
    state.banned = state.banned or {}
    state.cool = state.cool or {}
    state.lastReport = state.lastReport or {}
    state.pending = state.pending or {}
    return state
end

function Ban.IsBanned(state, name, now)
    local b = state.banned and state.banned[name]
    return b ~= nil and now < b.untilT
end

local function Entry(entries, name)
    for _, e in ipairs(entries) do
        if e.name == name then return e end
    end
end

function Ban.IsVoter(state, entries, name, now)
    if Ban.IsBanned(state, name, now) then return false end
    local e = Entry(entries, name)
    return e ~= nil and (e.distinct or 0) >= Ban.MIN_DISTINCT
end

function Ban.VoterCount(state, entries, now)
    local n = 0
    for _, e in ipairs(entries) do
        if Ban.IsVoter(state, entries, e.name, now) then n = n + 1 end
    end
    return n
end

function Ban.FindCase(state, id)
    for _, c in pairs(state.cases) do
        if c.id == id then return c end
    end
end

function Ban.Tally(case)
    local yes, no = 0, 0
    for _, v in pairs(case.votes) do
        if v then yes = yes + 1 else no = no + 1 end
    end
    return yes, no
end

-- c = { kind, reporter, target, reason, startTime }
function Ban.Open(state, entries, c, now)
    Ban.Ensure(state)
    if type(c) ~= "table" or type(c.reporter) ~= "string" or type(c.target) ~= "string"
        or (c.kind ~= "ban" and c.kind ~= "lift") or c.reporter == "" or c.target == "" then
        return false, "invalid"
    end
    if not Finite(c.startTime) or c.startTime <= 0 then return false, "invalid" end
    if c.startTime > now + Ban.MAX_CLOCK_SKEW then return false, "clock" end
    if now >= c.startTime + Ban.DURATION then return false, "expired" end
    if c.reporter == c.target then return false, "self" end
    if not Ban.IsVoter(state, entries, c.reporter, now) then return false, "not eligible" end
    if c.kind == "ban" then
        if Ban.IsBanned(state, c.target, now) then return false, "banned" end
        if not Entry(entries, c.target) then return false, "unknown target" end
        local cool = state.cool[c.target]
        if cool and c.startTime < cool then return false, "target cooldown" end
    elseif not Ban.IsBanned(state, c.target, now) then
        return false, "not banned"
    end
    local last = state.lastReport[c.reporter]
    if last and c.startTime - last < Ban.REPORT_COOLDOWN and c.startTime ~= last then
        return false, "report cooldown"
    end
    if Ban.VoterCount(state, entries, now) < Ban.MIN_VOTERS then return false, "few voters" end

    local case = {
        id = c.reporter .. "-" .. c.startTime,
        kind = c.kind, reporter = c.reporter, target = c.target,
        reason = ns.Home.TruncateUtf8(tostring(c.reason or ""), Ban.MAX_REASON),
        startTime = c.startTime,
        votes = { [c.reporter] = true },
        voteTimes = { [c.reporter] = c.startTime },
    }
    local existing = state.cases[c.target]
    if existing then
        if existing.id == case.id then return false, "duplicate" end
        if not Earlier(case, existing) then return false, "open" end
    end
    state.cases[c.target] = case
    state.lastReport[c.reporter] = c.startTime
    return true
end

function Ban.Vote(state, entries, voter, id, yes, now, ts)
    Ban.Ensure(state)
    local case = Ban.FindCase(state, id)
    if not case then return false, "no case" end
    if type(yes) ~= "boolean" then return false, "invalid" end
    ts = ts or now
    if not Finite(ts) then return false, "invalid" end
    if ts > now + Ban.MAX_CLOCK_SKEW then return false, "clock" end
    if now >= case.startTime + Ban.DURATION then return false, "closed" end
    if voter == case.target then return false, "target" end
    if not Ban.IsVoter(state, entries, voter, now) then return false, "not eligible" end
    local old = case.voteTimes[voter]
    if old and old >= ts then return true end
    case.votes[voter] = yes
    case.voteTimes[voter] = ts
    return true
end

local function Passed(yes, no)
    local total = yes + no
    return total >= Ban.MIN_VOTES and yes * 3 >= total * 2
end

-- Schliesst abgelaufene Anträge ab. Gibt eine Liste { target, kind, passed } zurück.
function Ban.Resolve(state, now)
    Ban.Ensure(state)
    local results = {}
    for target, case in pairs(state.cases) do
        local endT = case.startTime + Ban.DURATION
        if now >= endT then
            local yes, no = Ban.Tally(case)
            local ok = Passed(yes, no)
            if case.kind == "ban" then
                if ok then
                    state.banned[target] = { since = endT, untilT = endT + Ban.BAN_TIME }
                else
                    state.cool[target] = endT + Ban.REJECT_COOLDOWN
                end
            elseif ok then
                state.banned[target] = nil
            end
            state.cases[target] = nil
            results[#results + 1] = { target = target, kind = case.kind, passed = ok }
        end
    end
    for name, b in pairs(state.banned) do
        if now >= b.untilT then state.banned[name] = nil end
    end
    -- abgelaufene Sperrfristen und Melde-Zeitstempel entfernen (sonst wachsen sie ewig)
    for name, untilT in pairs(state.cool) do
        if now >= untilT then state.cool[name] = nil end
    end
    for name, t in pairs(state.lastReport) do
        if now - t >= Ban.REPORT_COOLDOWN then state.lastReport[name] = nil end
    end
    table.sort(results, function(a, b) return a.target < b.target end)
    return results
end

-- Ein anderer Spieler meldet einen verhängten Ausschluss. Erst wenn MIN_VOTES verschiedene
-- Stimmberechtigte dieselbe Meldung machen, wird sie übernommen (ein Einzelner kann nichts erzwingen).
function Ban.Announce(state, entries, sender, target, since, untilT, now)
    Ban.Ensure(state)
    if not (Finite(since) and Finite(untilT)) or type(target) ~= "string" or target == "" then return false end
    if untilT - since ~= Ban.BAN_TIME then return false end
    if since > now + Ban.MAX_CLOCK_SKEW or now >= untilT then return false end
    if sender == target or not Ban.IsVoter(state, entries, sender, now) then return false end
    local b = state.banned[target]
    if b and b.since == since then return false end
    local key = target .. "|" .. since
    local set = state.pending[key]
    if not set then
        local n = 0
        for _ in pairs(state.pending) do n = n + 1 end
        if n >= 200 then state.pending = {} end
        set = {}
        state.pending[key] = set
    end
    set[sender] = true
    local count = 0
    for _ in pairs(set) do count = count + 1 end
    if count < Ban.MIN_VOTES then return false end
    state.banned[target] = { since = since, untilT = untilT }
    state.cases[target] = nil
    state.pending[key] = nil
    return true
end
