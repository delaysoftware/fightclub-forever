local _, ns = ...

-- Reine Logik gegen Rating-Boosting (z. B. 300 Duelle mit demselben Freund). Läuft in jedem Client
-- auf der eigenen Historie; beide Duellseiten rechnen mit denselben Regeln.
local Boost = {}
ns.Boost = Boost

Boost.WINDOW = 24 * 3600             -- Zeitfenster für "pro Gegner" und Tageslimit
Boost.FULL = 3                       -- Duelle 1..3 gegen denselben Gegner zählen voll
Boost.HALF = 6                       -- Duelle 4..6 halb, danach gar nicht
Boost.DAILY_CAP = 150                -- max. Rating-Gewinn pro 24 h
Boost.SUSPECT_COUNT = 15             -- Hinweis ab so vielen Duellen mit demselben Gegner ...
Boost.SUSPECT_WINDOW = 7 * 24 * 3600 -- ... innerhalb dieser Zeit

-- Iteriert die Historie rückwärts, solange Einträge innerhalb des Fensters liegen.
local function Recent(history, now, window)
    local i = #history + 1
    return function()
        while true do
            i = i - 1
            local e = history[i]
            if not e or now - e.time >= window then return nil end -- Historie ist zeitlich sortiert
            if e.ranked ~= false then return e end -- Brawls (ranked == false) zählen nicht
        end
    end
end

function Boost.DuelsAgainst(history, opponent, now, window)
    local n = 0
    for e in Recent(history, now, window) do
        if e.opponent == opponent then n = n + 1 end
    end
    return n
end

-- Gewicht des nächsten Duells gegen opponent: 1, 0.5 oder 0.
function Boost.Weight(history, opponent, now)
    local n = Boost.DuelsAgainst(history, opponent, now, Boost.WINDOW)
    if n < Boost.FULL then return 1 end
    if n < Boost.HALF then return 0.5 end
    return 0
end

function Boost.GainedToday(history, now)
    local sum = 0
    for e in Recent(history, now, Boost.WINDOW) do
        if (e.delta or 0) > 0 then sum = sum + e.delta end
    end
    return sum
end

local function Round(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

-- Gibt neues Rating, Delta, Gewicht und ob das Tageslimit gegriffen hat zurück.
function Boost.Apply(history, opponent, won, rating, oppRating, now)
    local raw
    if won then
        raw = ns.CalcElo(rating, oppRating) - rating
    else
        local _, newRating = ns.CalcElo(oppRating, rating)
        raw = newRating - rating
    end
    local weight = Boost.Weight(history, opponent, now)
    local delta, capped = Round(raw * weight), false
    if delta > 0 then
        local room = math.max(0, Boost.DAILY_CAP - Boost.GainedToday(history, now))
        if delta > room then delta, capped = room, true end
    end
    if rating + delta < 0 then delta = -rating end
    return rating + delta, delta, weight, capped
end

-- Anzahl verschiedener Gegner, gegen die mindestens ein gewerteter Sieg vorliegt.
function Boost.DistinctWins(history, won)
    if won then
        -- Persistente Menge (bleibt auch bestehen, wenn alte Historie abgeschnitten wird)
        local c = 0
        for _ in pairs(won) do c = c + 1 end
        return c
    end
    local seen, n = {}, 0
    for _, e in ipairs(history) do
        if e.won and e.ranked ~= false and (e.weight == nil or e.weight > 0) and not seen[e.opponent] then
            seen[e.opponent] = true
            n = n + 1
        end
    end
    return n
end

-- Brawl-Direktvergleich: Siege und Niederlagen in ungewerteten Duellen gegen opponent seit "since" (Zeitstempel
-- des letzten vereinbarten Resets, nil = seit Beginn).
function Boost.H2H(history, opponent, since)
    local w, l = 0, 0
    for _, e in ipairs(history) do
        if e.ranked == false and e.opponent == opponent and (since == nil or e.time > since) then
            if e.won then w = w + 1 else l = l + 1 end
        end
    end
    return w, l
end

-- Bilanz gegen jeden Gegner: Liste { name, rw, rl, bw, bl, last } (Ranked-W/L, Brawl-W/L, Zeit des letzten Duells).
-- Gewertete Duelle ohne Rating (weight == 0) zählen nicht mit, Brawls immer.
function Boost.Rivals(history)
    local by, list = {}, {}
    for _, e in ipairs(history) do
        local r = by[e.opponent]
        if not r then
            r = { name = e.opponent, rw = 0, rl = 0, bw = 0, bl = 0, last = 0 }
            by[e.opponent] = r
            list[#list + 1] = r
        end
        if e.time > r.last then r.last = e.time end
        if e.ranked == false then
            if e.won then r.bw = r.bw + 1 else r.bl = r.bl + 1 end
        elseif e.weight == nil or e.weight > 0 then
            if e.won then r.rw = r.rw + 1 else r.rl = r.rl + 1 end
        end
    end
    return list
end

-- Gegner mit auffällig vielen Duellen im Beobachtungszeitraum (oder nil).
function Boost.Suspicious(history, now)
    local counts, bestName, best = {}, nil, 0
    for e in Recent(history, now, Boost.SUSPECT_WINDOW) do
        local c = (counts[e.opponent] or 0) + 1
        counts[e.opponent] = c
        if c > best then bestName, best = e.opponent, c end
    end
    if best >= Boost.SUSPECT_COUNT then return bestName, best end
end
