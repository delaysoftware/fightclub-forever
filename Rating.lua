local _, ns = ...

-- Reine Logik, ohne WoW-API, damit ausserhalb des Clients testbar.
-- Rangnamen und Schwellenwerte sind Platzhalter (noch nicht entschieden).
ns.RANKS = {
    -- opp = Siege gegen so viele verschiedene Gegner sind nötig (gegen Boosting zu zweit)
    -- icon = eigenes Rang-Symbol (Media\rank_<name>.tga, 128x128, rund mit Alpha; zeigt WoW ein grünes Quadrat,
    -- fehlt die Datei – dann mit /fc badges text auf reinen Text umschalten)
    { min = 0,    opp = 0,  name = "Rookie",   color = "ff9d9d9d", icon = "Interface\\AddOns\\Fightclub\\Media\\rank_rookie" },
    { min = 1000, opp = 0,  name = "Brawler",  color = "ffcd7f32", icon = "Interface\\AddOns\\Fightclub\\Media\\rank_brawler" },
    { min = 1200, opp = 3,  name = "Fighter",  pct = 0.30, color = "ffc0c0c0", icon = "Interface\\AddOns\\Fightclub\\Media\\rank_fighter" },
    { min = 1400, opp = 6,  name = "Champion", pct = 0.10, color = "ffffc800", icon = "Interface\\AddOns\\Fightclub\\Media\\rank_champion" },
    { min = 1600, opp = 10, name = "Legend",   pct = 0.03, color = "ffff2a2a", icon = "Interface\\AddOns\\Fightclub\\Media\\rank_legend" },
}

function ns.RankText(rating, distinct)
    local r = ns.GetRank(rating, distinct)
    return "|c" .. r.color .. r.name .. "|r"
end

-- Rangname mit vorangestelltem Symbol (|T..|t); noIcon = true liefert nur den Text.
function ns.RankLabel(rating, distinct, noIcon)
    local r = ns.GetRank(rating, distinct)
    local text = "|c" .. r.color .. r.name .. "|r"
    if noIcon or not r.icon then return text end
    return "|T" .. r.icon .. ":16:16|t " .. text
end

-- Rangfarbe als r, g, b (0..1).
function ns.RankColor(rating, distinct)
    local hex = ns.GetRank(rating, distinct).color
    return tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, tonumber(hex:sub(7, 8), 16) / 255
end

-- Stufe 1..5 des Rangs (für gestaffelte Verzierungen).
function ns.RankTier(rating, distinct)
    local rank = ns.GetRank(rating, distinct)
    for i, x in ipairs(ns.RANKS) do
        if x == rank then return i end
    end
    return 1
end

local K = 32

-- Prozentgrenzen für die oberen Ränge (pct = Anteil der besten aktiven Mitglieder). Erst ab MIN_ACTIVE aktiven
-- Mitgliedern, sonst wäre der Rang bei wenigen Spielern zufällig. Aktiv = in den letzten ACTIVE_DAYS gesehen.
ns.PCT = { ACTIVE_DAYS = 30, MIN_ACTIVE = 20 }

-- entries: { rating, lastSeen (nil = aktiv, z. B. man selbst) }. Gibt nil zurück, wenn es zu wenige aktive gibt,
-- sonst { active = n, ratings = absteigend, [Rangname] = Mindest-Rating }.
function ns.ComputeCutoffs(entries, now)
    local ratings = {}
    for _, e in ipairs(entries) do
        if e.lastSeen == nil or now - e.lastSeen <= ns.PCT.ACTIVE_DAYS * 86400 then
            ratings[#ratings + 1] = e.rating
        end
    end
    if #ratings < ns.PCT.MIN_ACTIVE then return nil end
    table.sort(ratings, function(a, b) return a > b end)
    local cut = { active = #ratings, ratings = ratings }
    for _, rank in ipairs(ns.RANKS) do
        if rank.pct then
            local n = math.max(1, math.floor(#ratings * rank.pct))
            cut[rank.name] = ratings[n]
        end
    end
    return cut
end

-- Anteil der aktiven Mitglieder mit höherem Rating (in Prozent, mind. 1) oder nil.
function ns.TopPercent(rating, cutoffs)
    cutoffs = cutoffs == nil and ns.cutoffs or cutoffs
    if not cutoffs then return nil end
    local better = 0
    for _, r in ipairs(cutoffs.ratings) do
        if r > rating then better = better + 1 else break end
    end
    return math.max(1, math.ceil((better + 1) / cutoffs.active * 100))
end

-- distinct (optional): Zahl verschiedener besiegter Gegner; nil = keine Gegner-Bedingung.
-- cutoffs (optional): Prozentgrenzen aus ComputeCutoffs; nil = zuletzt berechnete (ns.cutoffs), false = ignorieren.
function ns.GetRank(rating, distinct, cutoffs)
    if cutoffs == nil then cutoffs = ns.cutoffs end
    local result = ns.RANKS[1]
    for _, rank in ipairs(ns.RANKS) do
        if rating >= rank.min and (distinct == nil or distinct >= (rank.opp or 0))
            and (not cutoffs or not rank.pct or rating >= cutoffs[rank.name]) then
            result = rank
        end
    end
    return result
end

-- Standard-Elo. Gibt die neuen Ratings (winner, loser) zurück.
function ns.CalcElo(winnerRating, loserRating)
    local expected = 1 / (1 + 10 ^ ((loserRating - winnerRating) / 400))
    local delta = math.floor(K * (1 - expected) + 0.5)
    return winnerRating + delta, loserRating - delta
end
