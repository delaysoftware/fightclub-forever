local _, ns = ...

-- DUEL_FINISHED liefert kein Ergebnis; Sieger/Verlierer stehen nur in der Systemmeldung
-- (DUEL_WINNER_KNOCKOUT / DUEL_WINNER_RETREAT). Muster aus den lokalisierten Globals bauen.
-- TODO: im Forever-Client verifizieren, dass diese Globals/Events existieren.
local patterns = {}
local seenFmt = {}
local function AddFormat(fmt)
    if type(fmt) == "string" and not seenFmt[fmt] then
        seenFmt[fmt] = true
        patterns[#patterns + 1] = ns.DuelParse.Compile(fmt)
    end
end
for _, key in ipairs({ "DUEL_WINNER_KNOCKOUT", "DUEL_WINNER_RETREAT" }) do AddFormat(_G[key]) end
for _, fmt in ipairs(ns.DuelParse.DEFAULTS) do AddFormat(fmt) end

-- Diagnose für /fc debug: letzte duellbezogene Meldungen und Events.
ns.dbg = ns.dbg or { count = 0 }
ns.dbg.duel = {}
local function Log(text)
    local l = ns.dbg.duel
    l[#l + 1] = text
    if #l > 8 then table.remove(l, 1) end
end
for _, ev in ipairs({ "DUEL_REQUESTED", "DUEL_FINISHED", "DUEL_INBOUNDS", "DUEL_OUTOFBOUNDS" }) do
    ns.RegisterEvent(ev, function(...) Log(ev .. " " .. table.concat({ tostringall(...) }, ",")) end)
end

-- Verbucht ein Duell. meta = { ts = Stempel des Duellendes, provisional = true }: Ein vorläufiger Eintrag zählt sofort
-- (Rating, Bilanz, Historie), ist als "pending" markiert und wird später bestätigt (ns.ConfirmDuel) oder zurückgenommen
-- (ns.RevertDuel), je nachdem, ob das Gegenstück des Gegners eintrifft. So gibt es sofort Rückmeldung, ohne dass ein
-- erfundenes Duell dauerhaft zählt. Gibt den Historieneintrag zurück.
function ns.CommitResult(opponent, won, unranked, meta)
    meta = meta or {}
    if ns.InvalidateEntries then ns.InvalidateEntries() end
    local db = ns.db
    local me = db.me
    local now = time()
    local tag = meta.provisional and " |cffa0a0a0[pending confirmation]|r" or ""
    local entry
    if unranked then
        -- Brawl: zählt nur in der Brawl-Bilanz, nicht für Rating, Rang oder Boost-Limits.
        if won then me.bw = (me.bw or 0) + 1 else me.bl = (me.bl or 0) + 1 end
        local m = db.members[opponent]
        entry = { time = now, opponent = opponent, won = won, delta = 0, weight = 0, ranked = false,
            level = UnitLevel("player"), oppLevel = m and m.level, ts = meta.ts, pending = meta.provisional,
            undo = { dbw = won and 1 or 0, dbl = won and 0 or 1 } }
        table.insert(db.history, entry)
        local sw, sl = ns.BrawlSeries(opponent)
        ns.Print((won and "Brawl win" or "Brawl loss") .. " against " .. opponent
            .. (" – series %d:%d (all Brawls %dW / %dL)"):format(sw, sl, me.bw or 0, me.bl or 0) .. tag)
    else
        local oppRating = db.members[opponent] and db.members[opponent].rating or 1000
        -- Boost-Sperren (Boost.lua): abnehmender Gewinn pro Gegner, Tageslimit.
        local before = me.rating
        local newRating, delta, weight, capped = ns.Boost.Apply(db.history, opponent, won, me.rating, oppRating, now)
        me.rating = newRating
        local dWin, dLoss = 0, 0
        if weight > 0 then -- Duelle ohne Wertung (zu oft gegen denselben Gegner) füllen die Bilanz nicht
            if won then me.wins = me.wins + 1; dWin = 1 else me.losses = me.losses + 1; dLoss = 1 end
        end
        local oppLevel = db.members[opponent] and db.members[opponent].level
        local addedWon = won and weight > 0 and not db.won[opponent]
        entry = { time = now, opponent = opponent, won = won, delta = delta, weight = weight,
            level = UnitLevel("player"), oppLevel = oppLevel, ts = meta.ts, pending = meta.provisional,
            undo = { dRating = newRating - before, dWin = dWin, dLoss = dLoss, addedWon = addedWon } }
        table.insert(db.history, entry)
        if won and weight > 0 then db.won[opponent] = true end
        ns.CharData.TrimHistory(db.history)
        local distinct = ns.Boost.DistinctWins(db.history, db.won)
        ns.Print((won and "Win" or "Loss") .. " against " .. opponent .. " – Rating " .. me.rating
            .. (" (%+d)"):format(delta) .. " (" .. ns.GetRank(me.rating, distinct).name .. ")" .. tag)
        if weight < 1 then
            ns.Print(weight == 0 and "No rating change: too many duels against this opponent in 24 h."
                or "Reduced rating change: repeated duels against this opponent in 24 h.")
        elseif capped then
            ns.Print("Daily rating gain limit reached.")
        end
        local rankNow = ns.GetRank(me.rating)
        if ns.GetRank(me.rating, distinct) ~= rankNow then
            ns.Print(("Rank %s needs wins against %d different opponents (you have %d)."):format(
                rankNow.name, rankNow.opp, distinct))
        end
        local suspect, count = ns.Boost.Suspicious(db.history, now)
        if suspect then
            ns.Print(("%d duels against %s in 7 days. Suspicious? /fc report %s <reason>"):format(count, suspect, suspect))
        end
    end
    if not meta.provisional then ns.AnnounceStand(opponent) end
    if ns.RefreshBoard then ns.RefreshBoard() end
    return entry
end

-- Neuen Stand verteilen, damit Ranglisten anderer ohne Re-Login stimmen (erst nach Bestätigung, nie vorläufig).
function ns.AnnounceStand(opponent)
    ns.SendHello("WHISPER", opponent)
    if IsInGuild() then ns.SendHello("GUILD") end
    local grp = ns.Net.GroupChannel()
    if grp then ns.SendHello(grp) end
end

-- Offenen (vorläufigen) Eintrag zu einem Duell suchen.
local function FindPending(opponent, ts)
    local h = ns.db.history
    for i = #h, 1, -1 do
        local e = h[i]
        if e.pending and e.ts == ts and e.opponent == opponent then return e, i end
    end
end

-- Vorläufigen Eintrag bestätigen. Gibt true zurück, wenn es einen gab.
function ns.ConfirmDuel(opponent, ts)
    local e = FindPending(opponent, ts)
    if not e then return false end
    e.pending, e.undo = nil, nil
    ns.AnnounceStand(opponent)
    if ns.InvalidateEntries then ns.InvalidateEntries() end
    if ns.RefreshBoard then ns.RefreshBoard() end
    return true
end

-- Vorläufigen Eintrag zurücknehmen (Rating, Bilanz, Gegnerliste, Historie). silent = keine Meldung.
function ns.RevertDuel(opponent, ts, silent)
    local e, i = FindPending(opponent, ts)
    if not e then return false end
    local u, me = e.undo or {}, ns.db.me
    me.rating = math.max(0, me.rating - (u.dRating or 0))
    me.wins = math.max(0, me.wins - (u.dWin or 0))
    me.losses = math.max(0, me.losses - (u.dLoss or 0))
    me.bw = math.max(0, (me.bw or 0) - (u.dbw or 0))
    me.bl = math.max(0, (me.bl or 0) - (u.dbl or 0))
    if u.addedWon then ns.db.won[opponent] = nil end
    table.remove(ns.db.history, i)
    if ns.InvalidateEntries then ns.InvalidateEntries() end
    if not silent then ns.Print("Duel against", opponent, "was not confirmed and has been removed again.") end
    if ns.RefreshBoard then ns.RefreshBoard() end
    return true
end

ns.RegisterEvent("CHAT_MSG_SYSTEM", function(msg)
    if msg:lower():find("duel", 1, true) then Log("SYS " .. msg) end
    for _, p in ipairs(patterns) do
        local winner, loser = ns.DuelParse.Match(msg, p)
        if winner then
            if ns.IsSelf(winner) then ns.ClaimResult(loser, true)
            elseif ns.IsSelf(loser) then ns.ClaimResult(winner, false) end
            return
        end
    end
end)
