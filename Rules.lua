local _, ns = ...

-- Texte für die Tabs "Rules" und "Ranks". Die Regeln des Films, übersetzt auf die echten Mechaniken des Addons.
-- Zahlen kommen aus den Konstanten (Boost, Ban, Home, RANKS), damit Text und Verhalten nicht auseinanderlaufen.
local GOLD = "|cffffd100"

local function Rule(n, title, body)
    return ("%s%d. %s|r\n%s\n"):format(GOLD, n, title, body)
end

function ns.RulesText()
    local B, Bn, H = ns.Boost, ns.Ban, ns.Home
    local out = { GOLD .. "The Rules of Fightclub|r\n" }

    out[#out + 1] = Rule(1, "You do not talk about Fightclub.",
        "The addon works in silence. It never posts to chat for you, and its network channel stays hidden.")
    out[#out + 1] = Rule(2, "You DO NOT talk about Fightclub.",
        ("Accuse nobody in chat. Report cheaters with /fc report <player> <reason> and let the club vote: %d h, at least %d votes, 2/3 must say yes. Guilty means out for %d days."):format(
            Bn.DURATION / 3600, Bn.MIN_VOTES, Bn.BAN_TIME / 86400))
    out[#out + 1] = Rule(3, "If someone says stop, goes limp or taps out, the fight is over.",
        "A retreat counts as a loss. A duel counts at once, marked as pending. It becomes final when the other fighter confirms it and is removed again if he does not.")
    out[#out + 1] = Rule(4, "Only two fighters to a fight.",
        "Duels are one on one and both fighters need the addon. Right-click a player: \"Fightclub duel (ranked)\" counts for Rating and Rank, \"Fightclub duel (unranked)\" is a Brawl with no stakes.")
    out[#out + 1] = Rule(5, "One fight at a time, one opponent at a time.",
        ("Against the same opponent, duels 1-%d in 24 h count fully, %d-%d count half, after that nothing. The ladder is for fighting the whole club."):format(
            B.FULL, B.FULL + 1, B.HALF))
    out[#out + 1] = Rule(6, "No shirts, no shoes.",
        "Gear and level do not count. Everyone starts at 1000 Rating and only wins and losses move it (Elo). Level is shown for context only.")
    out[#out + 1] = Rule(7, "Fights go on as long as they have to.",
        ("But the climb is steady: at most +%d Rating per 24 hours."):format(B.DAILY_CAP))
    out[#out + 1] = Rule(8, "If this is your first night at Fightclub, you have to fight.",
        ("Rank needs wins against different opponents, not against one friend. Voting rights need wins against %d different opponents."):format(
            Bn.MIN_DISTINCT))

    out[#out + 1] = "Ranks and what they need: see the Ranks tab.\n"

    out[#out + 1] = GOLD .. "Where we meet|r"
    out[#out + 1] = ("The Top %d may propose a Fightclub location on the world map. 24 h vote, at least %d votes, simple majority. See the Fightclub tab."):format(
        H.TOP_N, H.MIN_VOTES)
    return table.concat(out, "\n")
end

-- Text für den Tab "Ranks": alle Ränge mit Anforderungen und der eigene Stand samt nächstem Ziel.
-- cutoffs: Ergebnis von ns.ComputeCutoffs (oder nil).
function ns.RanksText(rating, distinct, cutoffs)
    local out = { GOLD .. "Ranks|r\n" }
    local textOnly = ns.TextOnly and ns.TextOnly()
    for _, r in ipairs(ns.RANKS) do
        local icon = (not textOnly and r.icon) and ("|T" .. r.icon .. ":18:18|t ") or ""
        out[#out + 1] = icon .. ("|c%s%s|r"):format(r.color, r.name)
        local req = { ("Rating %d or more"):format(r.min) }
        if (r.opp or 0) > 0 then req[#req + 1] = ("wins against %d different opponents"):format(r.opp) end
        if r.pct then req[#req + 1] = ("top %d%% of active members"):format(r.pct * 100) end
        out[#out + 1] = "    " .. table.concat(req, ", ") .. "\n"
    end
    out[#out + 1] = ("Your rank is the highest one for which you meet all of its requirements. The top-percent limits apply once at least %d members were seen in the last %d days; below that only Rating and opponents count. Legend stays rare no matter how many join.\n"):format(
        ns.PCT.MIN_ACTIVE, ns.PCT.ACTIVE_DAYS)

    if rating then
        out[#out + 1] = GOLD .. "Your status|r"
        local cur = ns.GetRank(rating, distinct, cutoffs or false)
        out[#out + 1] = ("You: Rating %d, wins against %d different opponents -> %s"):format(rating, distinct or 0, cur.name)
        local nextRank
        for i, r in ipairs(ns.RANKS) do
            if r == cur then nextRank = ns.RANKS[i + 1] end
        end
        if not nextRank then
            out[#out + 1] = "You hold the highest rank."
        else
            local need = {}
            if rating < nextRank.min then need[#need + 1] = ("%d more Rating"):format(nextRank.min - rating) end
            local opp = nextRank.opp or 0
            if (distinct or 0) < opp then
                need[#need + 1] = ("wins against %d more different opponents"):format(opp - (distinct or 0))
            end
            if cutoffs and nextRank.pct and rating < cutoffs[nextRank.name] then
                need[#need + 1] = ("Rating %d to reach the top %d%%"):format(cutoffs[nextRank.name], nextRank.pct * 100)
            end
            out[#out + 1] = ("Next: %s%s"):format(nextRank.name,
                #need > 0 and (" - you still need " .. table.concat(need, ", ")) or " - you meet every requirement; keep winning.")
        end
    end
    return table.concat(out, "\n")
end
