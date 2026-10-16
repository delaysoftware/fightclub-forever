local ns = dofile("tests/load.lua")
local Home = ns.Home

local NOW = 1000000

local function entries(n)
    local t = {}
    for i = 1, n do t[i] = { name = "P" .. i, rating = 2000 - i } end
    return t -- P1 ist die Nummer 1; Top 10 = P1..P10
end

local function proposal(over)
    local p = { proposer = "P1", mapID = 1429, x = 0.5, y = 0.5, name = "Goldshire", startTime = NOW }
    for k, v in pairs(over or {}) do p[k] = v end
    return p
end

local function fresh() return { current = nil, proposal = nil } end

test("IsEligible: Top 10 ja, Platz 11 nein", function()
    local e = entries(12)
    truthy(Home.IsEligible(e, "P10"))
    eq(Home.IsEligible(e, "P11"), false)
    eq(Home.IsEligible(e, "Unbekannt"), false)
end)

test("IsEligible: Gleichstand entscheidet alphabetisch", function()
    local e = entries(9)
    e[#e + 1] = { name = "B", rating = 100 }
    e[#e + 1] = { name = "A", rating = 100 }
    truthy(Home.IsEligible(e, "A"))
    eq(Home.IsEligible(e, "B"), false)
end)

test("Propose: gültiger Vorschlag, Vorschlagender zählt als Ja", function()
    local s = fresh()
    local ok = Home.Propose(s, entries(12), proposal(), NOW)
    eq(ok, true)
    eq(s.proposal.id, "P1-" .. NOW)
    eq(s.proposal.votes.P1, true)
end)

test("Propose: nicht Berechtigte werden abgelehnt", function()
    local ok, why = Home.Propose(fresh(), entries(12), proposal({ proposer = "P11" }), NOW)
    eq(ok, false); eq(why, "not eligible")
end)

test("Propose: Zukunft über Toleranz = clock, Vergangenheit > 24h = expired", function()
    local _, a = Home.Propose(fresh(), entries(12), proposal({ startTime = NOW + 301 }), NOW)
    eq(a, "clock")
    local _, b = Home.Propose(fresh(), entries(12), proposal({ startTime = NOW - Home.DURATION }), NOW)
    eq(b, "expired")
    eq(Home.Propose(fresh(), entries(12), proposal({ startTime = NOW + 300 }), NOW), true)
end)

test("Propose: ungültige Koordinaten (nan, inf, >1, Text) werden abgelehnt", function()
    for _, bad in ipairs({ 0 / 0, math.huge, 1.5, -0.1, "0.5" }) do
        local ok, why = Home.Propose(fresh(), entries(12), proposal({ x = bad }), NOW)
        eq(ok, false); eq(why, "invalid")
    end
end)

test("Propose: Cooldown nach Wechsel", function()
    local s = { current = { mapID = 1, x = 0.1, y = 0.1, name = "Alt", since = NOW, epoch = 1 } }
    local ok, why = Home.Propose(s, entries(12), proposal({ startTime = NOW + 100 }), NOW + 100)
    eq(ok, false); eq(why, "cooldown")
    local later = NOW + Home.COOLDOWN
    eq(Home.Propose(s, entries(12), proposal({ startTime = later }), later), true)
end)

test("Propose: Konflikt – früherer Vorschlag gewinnt, späterer wird abgelehnt", function()
    local s = fresh()
    eq(Home.Propose(s, entries(12), proposal({ proposer = "P2", startTime = NOW + 10 }), NOW + 10), true)
    -- früherer trifft später ein
    eq(Home.Propose(s, entries(12), proposal({ proposer = "P3", startTime = NOW }), NOW + 10), true)
    eq(s.proposal.proposer, "P3")
    -- späterer wird abgelehnt
    local ok, why = Home.Propose(s, entries(12), proposal({ proposer = "P4", startTime = NOW + 20 }), NOW + 20)
    eq(ok, false); eq(why, "open")
    -- Duplikat
    local ok2, why2 = Home.Propose(s, entries(12), proposal({ proposer = "P3", startTime = NOW }), NOW + 20)
    eq(ok2, false); eq(why2, "duplicate")
end)

test("Propose: Gleiche startTime – kleinere id gewinnt auf allen Clients", function()
    local a, b = fresh(), fresh()
    local pa = proposal({ proposer = "P2" })
    local pb = proposal({ proposer = "P3" })
    Home.Propose(a, entries(12), pa, NOW); Home.Propose(a, entries(12), pb, NOW)
    Home.Propose(b, entries(12), pb, NOW); Home.Propose(b, entries(12), pa, NOW)
    eq(a.proposal.id, b.proposal.id)
    eq(a.proposal.proposer, "P2")
end)

test("Vote: berechtigt ok, unberechtigt/falsche id/geschlossen abgelehnt", function()
    local s = fresh()
    Home.Propose(s, entries(12), proposal(), NOW)
    local id = s.proposal.id
    eq(Home.Vote(s, entries(12), "P2", id, true, NOW + 5), true)
    local ok1, w1 = Home.Vote(s, entries(12), "P11", id, true, NOW + 5)
    eq(ok1, false); eq(w1, "not eligible")
    local ok2, w2 = Home.Vote(s, entries(12), "P3", "x-1", true, NOW + 5)
    eq(ok2, false); eq(w2, "no proposal")
    local ok3, w3 = Home.Vote(s, entries(12), "P3", id, true, NOW + Home.DURATION)
    eq(ok3, false); eq(w3, "closed")
end)

test("Vote: geänderte Stimme zählt einmal", function()
    local s = fresh()
    Home.Propose(s, entries(12), proposal(), NOW)
    local id = s.proposal.id
    Home.Vote(s, entries(12), "P2", id, true, NOW)
    Home.Vote(s, entries(12), "P2", id, false, NOW + 1)
    local yes, no = Home.Tally(s.proposal)
    eq(yes, 1); eq(no, 1)
end)

test("Resolve: vor Ablauf nichts; Annahme mit 3 Stimmen und Mehrheit", function()
    local s = fresh()
    Home.Propose(s, entries(12), proposal(), NOW)
    local id = s.proposal.id
    Home.Vote(s, entries(12), "P2", id, true, NOW)
    Home.Vote(s, entries(12), "P3", id, false, NOW)
    eq(Home.Resolve(s, NOW + Home.DURATION - 1), nil)
    eq(Home.Resolve(s, NOW + Home.DURATION), "adopted") -- 2 Ja, 1 Nein, 3 Stimmen
    eq(s.current.epoch, 1)
    eq(s.current.since, NOW + Home.DURATION)
    eq(s.current.name, "Goldshire")
    eq(s.proposal, nil)
end)

test("Resolve: genau 2 Stimmen oder Gleichstand werden abgelehnt", function()
    local s = fresh()
    Home.Propose(s, entries(12), proposal(), NOW)
    Home.Vote(s, entries(12), "P2", s.proposal.id, true, NOW)
    eq(Home.Resolve(s, NOW + Home.DURATION), "rejected") -- nur 2 Stimmen
    eq(s.current, nil)

    local t = fresh()
    Home.Propose(t, entries(12), proposal(), NOW)
    Home.Vote(t, entries(12), "P2", t.proposal.id, false, NOW)
    Home.Vote(t, entries(12), "P3", t.proposal.id, true, NOW)
    Home.Vote(t, entries(12), "P4", t.proposal.id, false, NOW)
    eq(Home.Resolve(t, NOW + Home.DURATION), "rejected") -- 2:2
end)

test("Resolve: epoch zählt hoch, Stimmen bleiben gültig auch wenn Wähler abgestiegen sind", function()
    local s = { current = { mapID = 1, x = 0.1, y = 0.1, name = "Alt", since = NOW - Home.COOLDOWN, epoch = 4 } }
    Home.Propose(s, entries(12), proposal(), NOW)
    Home.Vote(s, entries(12), "P2", s.proposal.id, true, NOW)
    Home.Vote(s, entries(12), "P3", s.proposal.id, true, NOW)
    -- Resolve kennt keine entries: Rating-Änderungen ändern nichts
    eq(Home.Resolve(s, NOW + Home.DURATION), "adopted")
    eq(s.current.epoch, 5)
end)

test("MergeCurrent: höhere epoch gewinnt, niedrigere/gleiche nicht; veralteter Vorschlag fällt weg", function()
    local s = fresh()
    Home.Propose(s, entries(12), proposal(), NOW)
    local c = { mapID = 9, x = 0.2, y = 0.3, name = "Neu", since = NOW + Home.DURATION, epoch = 1 }
    eq(Home.MergeCurrent(s, c, NOW + Home.DURATION), true)
    eq(s.current.name, "Neu")
    eq(s.proposal, nil) -- startTime + DURATION <= since
    -- gleiche epoch, späteres since verliert gegen das aktuelle
    eq(Home.MergeCurrent(s, { mapID = 1, x = 0, y = 0, name = "X", since = c.since + 1, epoch = 1 }, c.since + 1), false)
    eq(s.current.name, "Neu")
end)

test("MergeCurrent: späterer Vorschlag bleibt erhalten", function()
    local s = fresh()
    Home.Propose(s, entries(12), proposal({ startTime = NOW + 5000 }), NOW + 5000)
    local c = { mapID = 9, x = 0.2, y = 0.3, name = "Neu", since = NOW + Home.DURATION, epoch = 1 }
    Home.MergeCurrent(s, c, NOW + Home.DURATION)
    truthy(s.proposal)
end)

test("Propose: ungültige startTime (NaN, inf, -inf, -5, 0) werden abgelehnt", function()
    for _, bad in ipairs({ 0 / 0, math.huge, -math.huge, -5, 0 }) do
        local s = fresh()
        local ok, why = Home.Propose(s, entries(12), proposal({ startTime = bad }), NOW)
        eq(ok, false); eq(why, "invalid"); eq(s.proposal, nil)
    end
end)

test("Propose: ungültige mapID (NaN, inf) wird abgelehnt", function()
    for _, bad in ipairs({ 0 / 0, math.huge }) do
        local s = fresh()
        local ok, why = Home.Propose(s, entries(12), proposal({ mapID = bad }), NOW)
        eq(ok, false); eq(why, "invalid"); eq(s.proposal, nil)
    end
end)

test("MergeCurrent: fehlerhaftes c gibt false zurück, ohne Fehler – mit und ohne current", function()
    local bads = {
        { epoch = "x", mapID = 1, x = 0, y = 0, name = "N", since = 1 },
        { mapID = 1, x = 0, y = 0, name = "N", since = 1 },
        { epoch = 1, mapID = 1, x = 0, y = 0, name = "N", since = 0 / 0 },
        { epoch = 1, mapID = 1, x = 2, y = 0, name = "N", since = 1 },
        { epoch = 1, mapID = 1, x = 0, y = 0, name = 5, since = 1 },
        {},
    }
    for _, withCur in ipairs({ false, true }) do
        for _, c in ipairs(bads) do
            local s = fresh()
            if withCur then s.current = { mapID = 1, x = 0.1, y = 0.1, name = "Alt", since = NOW, epoch = 1 } end
            local ok, res = pcall(Home.MergeCurrent, s, c, NOW + Home.DURATION)
            truthy(ok, "must not raise")
            eq(res, false)
        end
    end
end)

test("MergeCurrent: speichert bereinigte Kopie mit gekürztem Namen", function()
    local s = fresh()
    local c = { mapID = 9, x = 0.2, y = 0.3, name = string.rep("X", 40), since = NOW + Home.DURATION, epoch = 1 }
    eq(Home.MergeCurrent(s, c, NOW + Home.DURATION), true)
    eq(#s.current.name, Home.MAX_NAME)
    truthy(s.current ~= c)
end)

-- ===== Final-Review-Fixes =====
local D2 = Home.COOLDOWN + Home.DURATION

local function cur(over)
    local c = { mapID = 9, x = 0.2, y = 0.3, name = "Neu", since = NOW, epoch = 1 }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

test("I1: gefälschte CUR (epoch 2^31-1, ferne Zukunft) wird abgelehnt, Zustand unverändert", function()
    local s = fresh()
    eq(Home.MergeCurrent(s, cur({ epoch = 2 ^ 31 - 1 }), NOW), false)
    eq(s.current, nil)
    eq(Home.MergeCurrent(s, cur({ since = NOW + 1000 }), NOW), false) -- since > now + skew
    eq(s.current, nil)
    s.current = cur({ epoch = 3, since = NOW })
    local later = NOW + D2
    eq(Home.MergeCurrent(s, cur({ epoch = 2 ^ 31 - 1, since = later }), later), false)
    eq(Home.MergeCurrent(s, cur({ epoch = 4, since = later + 10 * D2 }), later), false) -- Zukunft
    eq(Home.MergeCurrent(s, cur({ epoch = 5, since = later }), later), false) -- zwei Wechsel in 48 h
    eq(Home.MergeCurrent(s, cur({ epoch = 4, since = NOW + D2 - 1 }), NOW + D2), false) -- zu früh
    eq(s.current.epoch, 3)
end)

test("I1: legitime nächste epoch (since = alt + 48 h) wird akzeptiert", function()
    local s = { current = cur({ epoch = 3, since = NOW }) }
    local c = cur({ epoch = 4, since = NOW + D2, name = "Next" })
    eq(Home.MergeCurrent(s, c, NOW + D2), true)
    eq(s.current.epoch, 4); eq(s.current.name, "Next")
    eq(Home.MergeCurrent(fresh(), cur({ epoch = 1, since = NOW }), NOW), true)
    eq(Home.MergeCurrent(fresh(), cur({ epoch = 50, since = NOW }), NOW), false)
end)

test("I4: gleiche epoch – kleinere since gewinnt, bei Gleichstand der Schlüssel; Reihenfolge egal", function()
    local a = cur({ epoch = 2, since = NOW, name = "Zeta" })
    local b = cur({ epoch = 2, since = NOW + 5, name = "Alpha" })
    local x, y = { current = cur(a) }, { current = cur(b) }
    Home.MergeCurrent(x, b, NOW + 10); Home.MergeCurrent(y, a, NOW + 10)
    eq(x.current.name, "Zeta"); eq(y.current.name, "Zeta")
    local c1 = cur({ epoch = 2, since = NOW, name = "Beta" })
    local c2 = cur({ epoch = 2, since = NOW, name = "Alpha" })
    local p, q = { current = cur(c1) }, { current = cur(c2) }
    Home.MergeCurrent(p, c2, NOW); Home.MergeCurrent(q, c1, NOW)
    eq(p.current.name, "Alpha"); eq(q.current.name, "Alpha")
    eq(Home.MergeCurrent(p, c2, NOW), false) -- identisch: keine Änderung
    eq(Home.MergeCurrent(p, cur({ epoch = 2, since = NOW - 1, name = "Z" }), NOW - 1000), false) -- Zukunft
end)

test("I3: Stimme mit späterem Zeitstempel gewinnt in beiden Reihenfolgen", function()
    for _, order in ipairs({ { 1, 2 }, { 2, 1 } }) do
        local s = fresh()
        Home.Propose(s, entries(12), proposal(), NOW)
        local id = s.proposal.id
        local votes = { { false, NOW + 10 }, { true, NOW + 20 } }
        for _, i in ipairs(order) do
            eq(Home.Vote(s, entries(12), "P2", id, votes[i][1], NOW + 30, votes[i][2]), true)
        end
        eq(s.proposal.votes.P2, true)
        eq(s.proposal.voteTimes.P2, NOW + 20)
    end
end)

test("I3: veraltetes Relay überschreibt nicht; Gleichstand behält alte Stimme; ts in Zukunft = clock", function()
    local s = fresh()
    Home.Propose(s, entries(12), proposal(), NOW)
    local id = s.proposal.id
    eq(s.proposal.voteTimes.P1, NOW)
    Home.Vote(s, entries(12), "P2", id, true, NOW + 50, NOW + 40)
    eq(Home.Vote(s, entries(12), "P2", id, false, NOW + 50, NOW + 30), true)
    eq(s.proposal.votes.P2, true)
    eq(Home.Vote(s, entries(12), "P2", id, false, NOW + 50, NOW + 40), true)
    eq(s.proposal.votes.P2, true)
    local ok, why = Home.Vote(s, entries(12), "P2", id, false, NOW + 50, NOW + 50 + 301)
    eq(ok, false); eq(why, "clock")
    local yes, no = Home.Tally(s.proposal)
    eq(yes, 2); eq(no, 0)
end)

test("M1: TruncateUtf8 trennt keine Mehrbyte-Zeichen", function()
    local s = string.rep("a", 15) .. "\195\188" -- 15 x a + ü (2 Bytes)
    eq(Home.TruncateUtf8(s, 16), string.rep("a", 15))
    eq(Home.TruncateUtf8(s, 17), s)
    eq(Home.TruncateUtf8("abc", 16), "abc")
    eq(Home.TruncateUtf8("\226\130\172\226\130\172", 4), "\226\130\172") -- 3-Byte-Zeichen
    local st = fresh()
    Home.Propose(st, entries(12), proposal({ name = s }), NOW)
    eq(st.proposal.name, string.rep("a", 15))
    local m = fresh()
    Home.MergeCurrent(m, cur({ name = s }), NOW)
    eq(m.current.name, string.rep("a", 15))
end)

test("Home.DEFAULTS: Standard-Orte für beide Fraktionen mit gültigen Koordinaten", function()
    for _, faction in ipairs({ "Horde", "Alliance" }) do
        local d = ns.Home.DEFAULTS[faction]
        truthy(d, faction .. " fehlt")
        truthy(type(d.mapID) == "number" and d.mapID > 0)
        truthy(d.x >= 0 and d.x <= 1 and d.y >= 0 and d.y <= 1, "Koordinaten ausserhalb 0..1")
        truthy(#d.name > 0 and #d.name <= ns.Home.MAX_NAME + 8)
    end
end)
