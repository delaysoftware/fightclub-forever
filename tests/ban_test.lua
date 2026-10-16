local ns = dofile("tests/load.lua")
local Ban = ns.Ban
local NOW = 5000000
local D = Ban.DURATION

-- 8 Spieler mit je 3 verschiedenen besiegten Gegnern = stimmberechtigt; N1 hat nur 1 = nicht.
local function entries()
    local t = {}
    for i = 1, 8 do t[#t + 1] = { name = "P" .. i, rating = 1000 + i, distinct = 3 } end
    t[#t + 1] = { name = "Newbie", rating = 1000, distinct = 1 }
    t[#t + 1] = { name = "Cheater", rating = 1500, distinct = 6 }
    return t
end

local function case(over)
    local c = { kind = "ban", reporter = "P1", target = "Cheater", reason = "win trading", startTime = NOW }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local function fresh() return Ban.Ensure({}) end

local function voteAll(s, e, id, n, yes, ts)
    for i = 2, n do Ban.Vote(s, e, "P" .. i, id, yes, NOW + 10, ts or NOW + 10) end
end

test("Ban: Antrag von Stimmberechtigtem wird angenommen, Antragsteller stimmt Ja", function()
    local s, e = fresh(), entries()
    eq(Ban.Open(s, e, case(), NOW), true)
    local c = s.cases.Cheater
    eq(c.votes.P1, true); eq(c.id, "P1-" .. NOW)
end)

test("Ban: Nicht-Stimmberechtigte (zu wenig verschiedene Gegner) dürfen nicht melden/abstimmen", function()
    local s, e = fresh(), entries()
    local ok, why = Ban.Open(s, e, case({ reporter = "Newbie" }), NOW)
    eq(ok, false); eq(why, "not eligible")
    Ban.Open(s, e, case(), NOW)
    local ok2, why2 = Ban.Vote(s, e, "Newbie", s.cases.Cheater.id, true, NOW)
    eq(ok2, false); eq(why2, "not eligible")
end)

test("Ban: man kann sich nicht selbst melden und das Ziel stimmt nicht mit", function()
    local s, e = fresh(), entries()
    eq(select(2, Ban.Open(s, e, case({ reporter = "P1", target = "P1" }), NOW)), "self")
    Ban.Open(s, e, case(), NOW)
    local ok, why = Ban.Vote(s, e, "Cheater", s.cases.Cheater.id, false, NOW)
    eq(ok, false); eq(why, "target")
end)

test("Ban: weniger als 5 Stimmberechtigte -> kein Antrag", function()
    local s, e = fresh(), {}
    for i = 1, 4 do e[#e + 1] = { name = "P" .. i, rating = 1000, distinct = 3 } end
    e[#e + 1] = { name = "Cheater", rating = 1000, distinct = 0 }
    eq(select(2, Ban.Open(s, e, case(), NOW)), "few voters")
end)

test("Ban: Reporter-Cooldown 24 h, nur ein Antrag je Ziel (früherer gewinnt)", function()
    local s, e = fresh(), entries()
    Ban.Open(s, e, case(), NOW)
    eq(select(2, Ban.Open(s, e, case({ target = "P5", startTime = NOW + 10 }), NOW + 10)), "report cooldown")
    eq(select(2, Ban.Open(s, e, case({ reporter = "P2", startTime = NOW + 20 }), NOW + 20)), "open")
    local ok = Ban.Open(s, e, case({ reporter = "P3", startTime = NOW - 50 }), NOW)
    eq(ok, true)
    eq(s.cases.Cheater.reporter, "P3")
end)

test("Ban: Antrag mit Zukunfts-/Vergangenheits-/ungültiger startTime wird abgelehnt", function()
    local s, e = fresh(), entries()
    eq(select(2, Ban.Open(s, e, case({ startTime = NOW + 10000 }), NOW)), "clock")
    eq(select(2, Ban.Open(s, e, case({ startTime = NOW - D - 1 }), NOW)), "expired")
    eq(select(2, Ban.Open(s, e, case({ startTime = 0 / 0 }), NOW)), "invalid")
    eq(select(2, Ban.Open(s, e, case({ startTime = math.huge }), NOW)), "invalid")
    eq(select(2, Ban.Open(s, e, case({ kind = "x" }), NOW)), "invalid")
end)

test("Ban: Resolve – 5 Stimmen, 2/3 Ja -> Ausschluss 30 Tage", function()
    local s, e = fresh(), entries()
    Ban.Open(s, e, case(), NOW)
    local id = s.cases.Cheater.id
    voteAll(s, e, id, 4, true)                     -- P1..P4 Ja
    Ban.Vote(s, e, "P5", id, false, NOW + 10)      -- 4 Ja, 1 Nein: 4*3 >= 5*2 -> 12 >= 10
    eq(#Ban.Resolve(s, NOW + D - 1), 0)
    local r = Ban.Resolve(s, NOW + D)
    eq(#r, 1); eq(r[1].passed, true)
    eq(s.banned.Cheater.untilT, NOW + D + Ban.BAN_TIME)
    eq(Ban.IsBanned(s, "Cheater", NOW + D + 5), true)
    eq(Ban.IsBanned(s, "Cheater", NOW + D + Ban.BAN_TIME), false)
end)

test("Ban: weniger als 2/3 oder weniger als 5 Stimmen -> abgelehnt, Cooldown 7 Tage", function()
    local s, e = fresh(), entries()
    Ban.Open(s, e, case(), NOW)
    local id = s.cases.Cheater.id
    voteAll(s, e, id, 3, true)                     -- 3 Ja nur
    eq(Ban.Resolve(s, NOW + D)[1].passed, false)   -- < 5 Stimmen
    eq(s.cool.Cheater, NOW + D + Ban.REJECT_COOLDOWN)
    eq(select(2, Ban.Open(s, e, case({ reporter = "P4", startTime = NOW + D + 100 }), NOW + D + 100)), "target cooldown")

    local s2 = fresh()
    Ban.Open(s2, e, case(), NOW)
    local id2 = s2.cases.Cheater.id
    voteAll(s2, e, id2, 3, true)                   -- P1..P3 Ja
    Ban.Vote(s2, e, "P4", id2, false, NOW + 10)
    Ban.Vote(s2, e, "P5", id2, false, NOW + 10)    -- 3 Ja, 2 Nein: 9 < 10
    eq(Ban.Resolve(s2, NOW + D)[1].passed, false)
end)

test("Ban: Stimme ändern – jüngster Zeitstempel gewinnt, Gleichstand behält alte", function()
    local s, e = fresh(), entries()
    Ban.Open(s, e, case(), NOW)
    local id = s.cases.Cheater.id
    Ban.Vote(s, e, "P2", id, true, NOW + 20, NOW + 20)
    Ban.Vote(s, e, "P2", id, false, NOW + 30, NOW + 10)  -- älter -> ignoriert
    eq(s.cases.Cheater.votes.P2, true)
    Ban.Vote(s, e, "P2", id, false, NOW + 40, NOW + 40)
    eq(s.cases.Cheater.votes.P2, false)
    Ban.Vote(s, e, "P2", id, true, NOW + 40, NOW + 40)   -- Gleichstand -> bleibt
    eq(s.cases.Cheater.votes.P2, false)
end)

test("Ban: Aufhebungsantrag entbannt bei Annahme; nur gegen Gebannte", function()
    local s, e = fresh(), entries()
    eq(select(2, Ban.Open(s, e, case({ kind = "lift" }), NOW)), "not banned")
    s.banned.Cheater = { since = NOW, untilT = NOW + Ban.BAN_TIME }
    local e2 = entries()
    for i, x in ipairs(e2) do if x.name == "Cheater" then table.remove(e2, i) break end end
    local t = NOW + 100
    eq(Ban.Open(s, e2, case({ kind = "lift", startTime = t }), t), true)
    local id = s.cases.Cheater.id
    for i = 2, 5 do Ban.Vote(s, e2, "P" .. i, id, true, t + 5, t + 5) end
    eq(Ban.Resolve(s, t + D)[1].passed, true)
    eq(s.banned.Cheater, nil)
end)

test("Ban: Gebannte können weder melden noch abstimmen", function()
    local s, e = fresh(), entries()
    s.banned.P2 = { since = NOW, untilT = NOW + Ban.BAN_TIME }
    eq(select(2, Ban.Open(s, e, case({ reporter = "P2" }), NOW)), "not eligible")
end)

test("Ban: Announce braucht 5 verschiedene Stimmberechtigte mit identischer Meldung", function()
    local s, e = fresh(), entries()
    local since, untilT = NOW - 100, NOW - 100 + Ban.BAN_TIME
    for i = 1, 4 do eq(Ban.Announce(s, e, "P" .. i, "Cheater", since, untilT, NOW), false) end
    eq(Ban.Announce(s, e, "P1", "Cheater", since, untilT, NOW), false)       -- doppelt zählt nicht
    eq(s.banned.Cheater, nil)
    eq(Ban.Announce(s, e, "P5", "Cheater", since, untilT, NOW), true)
    eq(s.banned.Cheater.untilT, untilT)
end)

test("Ban: Announce lehnt falsche Dauer, Zukunft, Abgelaufenes, Nicht-Stimmberechtigte ab", function()
    local s, e = fresh(), entries()
    eq(Ban.Announce(s, e, "P1", "Cheater", NOW, NOW + 5, NOW), false)                          -- Dauer
    eq(Ban.Announce(s, e, "P1", "Cheater", NOW + 99999, NOW + 99999 + Ban.BAN_TIME, NOW), false) -- Zukunft
    eq(Ban.Announce(s, e, "P1", "Cheater", NOW - Ban.BAN_TIME - 1, NOW - 1, NOW), false)       -- abgelaufen
    eq(Ban.Announce(s, e, "Newbie", "Cheater", NOW, NOW + Ban.BAN_TIME, NOW), false)           -- kein Stimmrecht
    eq(Ban.Announce(s, e, "Cheater", "Cheater", NOW, NOW + Ban.BAN_TIME, NOW), false)          -- Ziel selbst
    eq(Ban.Announce(s, e, "P1", "Cheater", 0 / 0, NOW, NOW), false)
end)

test("BanCodec: Roundtrip BCASE/BVOTE/BVOTES/BBAN mit zweiteiligen Namen", function()
    local C = ns.BanCodec
    local m = C.Decode(C.EncodeCase({ kind = "lift", reporter = "Anna Schmidt", target = "Bob Mueller", reason = "sorry, ok: fine", startTime = NOW }))
    eq(m.kind, "BCASE"); eq(m.c.kind, "lift"); eq(m.c.reporter, "Anna Schmidt"); eq(m.c.target, "Bob Mueller")
    eq(m.c.reason, "sorry ok fine"); eq(m.c.startTime, NOW)
    local v = C.Decode(C.EncodeVote("Anna Schmidt-5", false, NOW))
    eq(v.kind, "BVOTE"); eq(v.id, "Anna Schmidt-5"); eq(v.yes, false); eq(v.ts, NOW)
    local parts = C.EncodeVotes("x-1", { ["Anna Schmidt"] = true, Bob = false }, { ["Anna Schmidt"] = 5, Bob = 6 })
    local vs = C.Decode(parts[1])
    eq(vs.kind, "BVOTES"); eq(vs.votes["Anna Schmidt"], true); eq(vs.votes.Bob, false); eq(vs.times.Bob, 6)
    local b = C.Decode(C.EncodeBan("Bob Mueller", NOW, NOW + 100))
    eq(b.kind, "BBAN"); eq(b.target, "Bob Mueller"); eq(b.untilT, NOW + 100)
end)

test("BanCodec: kaputte Nachrichten ergeben nil", function()
    local C = ns.BanCodec
    for _, bad in ipairs({
        "", "BCASE|1|B|a|b|r", "BCASE|1|X|a|b|r|5", "BCASE|1|B|a||r|5", "BCASE|1|B|a|b|r|-5", "BCASE|2|B|a|b|r|5",
        "BVOTE|1|id|Z|5", "BVOTE|1||Y|5", "BVOTE|1|id|Y|x", "BVOTES|1|id|a:Y", "BVOTES|1|id|a:Q:5",
        "BBAN|1|t|5", "BBAN|1||5|6", "BBAN|1|t|x|6", "BBAN|1|t|5|6|7", "FOO|1|a",
    }) do eq(C.Decode(bad), nil, bad) end
end)
