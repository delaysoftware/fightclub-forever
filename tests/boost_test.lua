local ns = dofile("tests/load.lua")
local Boost = ns.Boost
local NOW = 1000000

local function hist(opp, n, won, delta, dt)
    local h = {}
    for i = 1, n do
        h[#h + 1] = { time = NOW - (dt or 100) * (n - i + 1), opponent = opp, won = won ~= false, delta = delta }
    end
    return h
end

test("Boost: Gewicht 1 / 0.5 / 0 je nach Duellen gegen denselben Gegner in 24 h", function()
    eq(Boost.Weight(hist("A", 2), "A", NOW), 1)
    eq(Boost.Weight(hist("A", 3), "A", NOW), 0.5)
    eq(Boost.Weight(hist("A", 5), "A", NOW), 0.5)
    eq(Boost.Weight(hist("A", 6), "A", NOW), 0)
    eq(Boost.Weight(hist("A", 6), "B", NOW), 1)
end)

test("Boost: Duelle älter als 24 h zählen nicht", function()
    eq(Boost.Weight(hist("A", 10, true, 5, 100000), "A", NOW), 1)
end)

test("Boost: Apply – volles Gewicht entspricht Elo, Gewicht 0 ändert nichts", function()
    local r, d, w = Boost.Apply({}, "A", true, 1000, 1000, NOW)
    eq(r, 1016); eq(d, 16); eq(w, 1)
    local r2, d2, w2 = Boost.Apply(hist("A", 6), "A", true, 1000, 1000, NOW)
    eq(r2, 1000); eq(d2, 0); eq(w2, 0)
    local r3 = Boost.Apply(hist("A", 6), "A", false, 1000, 1000, NOW)
    eq(r3, 1000)
end)

test("Boost: halbes Gewicht halbiert Gewinn und Verlust", function()
    local _, d = Boost.Apply(hist("A", 3), "A", true, 1000, 1000, NOW)
    eq(d, 8)
    local _, dl = Boost.Apply(hist("A", 3), "A", false, 1000, 1000, NOW)
    eq(dl, -8)
end)

test("Boost: Tageslimit +150 greift", function()
    local r, d, _, capped = Boost.Apply(hist("B", 1, true, 140), "C", true, 1000, 1000, NOW)
    eq(d, 10); eq(capped, true); eq(r, 1010)
    local r2, d2 = Boost.Apply(hist("B", 1, true, 150), "C", true, 1000, 1000, NOW)
    eq(d2, 0); eq(r2, 1000)
end)

test("Boost: Rating fällt nie unter 0", function()
    local r = Boost.Apply({}, "A", false, 5, 2000, NOW)
    truthy(r >= 0)
end)

test("Boost: DistinctWins zählt verschiedene Gegner, nur gewertete Siege", function()
    local h = {
        { opponent = "A", won = true }, { opponent = "A", won = true }, { opponent = "B", won = true, weight = 0 },
        { opponent = "C", won = false }, { opponent = "D", won = true, weight = 0.5 },
    }
    eq(Boost.DistinctWins(h), 2)
end)

test("Boost: Rang wird durch fehlende verschiedene Gegner gedeckelt", function()
    eq(ns.GetRank(1700, 0).name, "Brawler")
    eq(ns.GetRank(1700, 3).name, "Fighter")
    eq(ns.GetRank(1700, 6).name, "Champion")
    eq(ns.GetRank(1700, 10).name, "Legend")
    eq(ns.GetRank(1700).name, "Legend") -- ohne Angabe keine Bedingung
    eq(ns.GetRank(500, 99).name, "Rookie")
end)

test("Boost: Suspicious ab 15 Duellen mit demselben Gegner in 7 Tagen", function()
    local name, n = Boost.Suspicious(hist("A", 15, true, 1, 1000), NOW)
    eq(name, "A"); eq(n, 15)
    eq(Boost.Suspicious(hist("A", 14, true, 1, 1000), NOW), nil)
end)

test("Boost: Brawls (ranked == false) zählen weder für Gewicht, Tageslimit, verschiedene Gegner noch Verdacht", function()
    local h = {}
    for i = 1, 20 do h[#h + 1] = { time = NOW - 10 * (21 - i), opponent = "A", won = true, delta = 50, ranked = false } end
    eq(Boost.Weight(h, "A", NOW), 1)
    eq(Boost.GainedToday(h, NOW), 0)
    eq(Boost.DistinctWins(h), 0)
    eq(Boost.Suspicious(h, NOW), nil)
    -- gemischt: gewertete Duelle dahinter werden trotzdem gefunden
    local m = hist("A", 3)
    m[#m + 1] = { time = NOW - 1, opponent = "A", won = true, ranked = false }
    eq(Boost.Weight(m, "A", NOW), 0.5)
end)

test("Rules/Ranks: Regeltext hat 8 Regeln; Rangtext alle Ränge, Anforderungen und nächstes Ziel", function()
    local t = ns.RulesText()
    for i = 1, 8 do truthy(t:find(i .. "%. "), "Regel " .. i .. " fehlt") end
    truthy(t:find("+150 Rating", 1, true), "Tageslimit fehlt")
    truthy(t:find("2/3", 1, true))
    truthy(t:find("30 days", 1, true))
    local rt = ns.RanksText(1050, 1, nil)
    for _, r in ipairs(ns.RANKS) do truthy(rt:find(r.name, 1, true), r.name .. " fehlt") end
    truthy(rt:find("wins against 10 different", 1, true), "Legend-Bedingung fehlt")
    truthy(rt:find("top 3%", 1, true), "Legend-Prozent fehlt")
    truthy(rt:find("Next: Fighter", 1, true), rt)
    truthy(rt:find("150 more Rating", 1, true) and rt:find("2 more different opponents", 1, true), "fehlende Schritte")
    truthy(ns.RanksText(2000, 20, nil):find("highest rank", 1, true))
end)

test("DuelParse: Sieger/Verlierer richtig, auch bei vertauschter Textreihenfolge und Namen mit Leerzeichen", function()
    local P = ns.DuelParse
    local ko = P.Compile("%1$s has defeated %2$s in a duel.")
    local w, l = P.Match("Anna Schmidt has defeated Bob in a duel.", ko)
    eq(w, "Anna Schmidt"); eq(l, "Bob")
    local fled = P.Compile("%2$s has fled from %1$s in a duel.")
    w, l = P.Match("Bob has fled from Anna Schmidt in a duel.", fled)
    eq(w, "Anna Schmidt"); eq(l, "Bob")
    local plain = P.Compile("%s has defeated %s in a duel.")
    w, l = P.Match("A B has defeated C D in a duel.", plain)
    eq(w, "A B"); eq(l, "C D")
    eq(P.Match("irgendwas anderes", ko), nil)
end)

test("Rating: RankLabel mit Symbol, nur Text, und Rangfarbe", function()
    local l = ns.RankLabel(1700, 10)
    truthy(l:find("|T", 1, true) and l:find("Legend", 1, true), l)
    local plain = ns.RankLabel(1700, 10, true)
    truthy(not plain:find("|T", 1, true) and plain:find("Legend", 1, true))
    local r, g, b = ns.RankColor(1700, 10)
    truthy(math.abs(r - 1) < 0.01 and g < 0.2 and b < 0.2, "Legend ist rot")
    truthy(ns.RankLabel(1700, 0):find("Brawler", 1, true), "ohne Gegner nur Brawler")
end)

test("Rating: RankTier 1..5 folgt dem effektiven Rang", function()
    eq(ns.RankTier(500, 0), 1)
    eq(ns.RankTier(1000, 0), 2)
    eq(ns.RankTier(1700, 0), 2)  -- ohne Gegner gedeckelt
    eq(ns.RankTier(1300, 3), 3)
    eq(ns.RankTier(1700, 10), 5)
end)

test("Rating: Prozentgrenzen – Legend nur Top 3 %, Champion Top 10 %, erst ab 20 aktiven", function()
    local now, entries = 10000000, {}
    for i = 1, 30 do entries[#entries + 1] = { rating = 1760 + i } end -- 1761..1790
    local cut = ns.ComputeCutoffs(entries, now)
    eq(cut.active, 30)
    eq(cut.Legend, 1790)     -- floor(30*0.03)=0 -> mindestens 1
    eq(cut.Champion, 1788)   -- Top 3
    eq(cut.Fighter, 1782)    -- Top 9
    eq(ns.GetRank(1790, 10, cut).name, "Legend")
    eq(ns.GetRank(1789, 10, cut).name, "Champion")
    eq(ns.GetRank(1787, 10, cut).name, "Fighter")
    eq(ns.GetRank(1770, 10, cut).name, "Brawler")  -- hohe Hürde erfüllt, aber nicht in den oberen 30 %
    eq(ns.GetRank(1790, 10, false).name, "Legend")  -- false = Prozentgrenzen ignorieren
    eq(ns.TopPercent(1790, cut), 4)  -- 1 von 30 = 3,3 % -> aufgerundet 4
    eq(ns.TopPercent(1761, cut), 100)
end)

test("Rating: weniger als 20 aktive oder alte lastSeen -> keine Prozentgrenze", function()
    local now, entries = 10000000, {}
    for i = 1, 19 do entries[#entries + 1] = { rating = 1700 + i } end
    eq(ns.ComputeCutoffs(entries, now), nil)
    entries[#entries + 1] = { rating = 1500, lastSeen = now - 31 * 86400 }  -- inaktiv, zählt nicht
    eq(ns.ComputeCutoffs(entries, now), nil)
    entries[#entries + 1] = { rating = 1500, lastSeen = now - 5 * 86400 }
    eq(ns.ComputeCutoffs(entries, now).active, 20)
end)

test("Boost: H2H zählt nur Brawls gegen den Gegner nach dem Reset", function()
    local h = {
        { time = 100, opponent = "A", won = true, ranked = false },
        { time = 200, opponent = "A", won = false, ranked = false },
        { time = 300, opponent = "A", won = true, ranked = false },
        { time = 310, opponent = "A", won = true },                    -- gewertet: zählt nicht
        { time = 320, opponent = "B", won = true, ranked = false },   -- anderer Gegner
    }
    local w, l = Boost.H2H(h, "A")
    eq(w, 2); eq(l, 1)
    w, l = Boost.H2H(h, "A", 200)   -- Reset bei 200: nur Einträge danach
    eq(w, 1); eq(l, 0)
    w, l = Boost.H2H(h, "A", 300)
    eq(w, 0); eq(l, 0)
end)

test("Boost: Rivals aggregiert Ranked/Brawl getrennt, ignoriert Duelle ohne Wertung", function()
    local h = {
        { time = 100, opponent = "A", won = true },
        { time = 110, opponent = "A", won = false },
        { time = 120, opponent = "A", won = true, weight = 0 },           -- ohne Wertung
        { time = 130, opponent = "A", won = true, ranked = false },
        { time = 140, opponent = "B", won = false, ranked = false },
    }
    local list = Boost.Rivals(h)
    eq(#list, 2)
    local a = list[1]
    eq(a.name, "A"); eq(a.rw, 1); eq(a.rl, 1); eq(a.bw, 1); eq(a.bl, 0); eq(a.last, 130)
    local b = list[2]
    eq(b.rw, 0); eq(b.bl, 1); eq(b.last, 140)
end)

test("CharData: Statistiken pro Charakter getrennt; Altdaten werden verschoben und per Claim übernommen", function()
    local C = ns.CharData
    -- Altstand wie vor der Trennung: kontoweites me/history/h2h
    local db = { me = { rating = 1100, wins = 3, losses = 1 }, history = { { opponent = "A", won = true, time = 1 } }, h2h = {} }
    eq(C.MigrateLegacy(db), true)
    eq(db.me, nil); eq(db.legacy.me.wins, 3)
    eq(C.MigrateLegacy(db), true)  -- zweiter Aufruf ändert nichts
    local a = C.Get(db, "Omi-Realm")
    local b = C.Get(db, "Zweit-Realm")
    eq(a.me.wins, 0); eq(b.me.wins, 0); truthy(a ~= b and a.me ~= b.me and a.history ~= b.history)
    a.me.wins = 5
    eq(C.Get(db, "Omi-Realm").me.wins, 5); eq(b.me.wins, 0)
    -- Claim: nur für frische Charaktere, sonst force
    local ok1, why1 = C.Claim(db, "Omi-Realm")
    eq(ok1, false); eq(why1, "not fresh")
    local ok2 = C.Claim(db, "Zweit-Realm")
    eq(ok2, true); eq(C.Get(db, "Zweit-Realm").me.wins, 3); eq(db.legacy, nil)
    eq(select(2, C.Claim(db, "Zweit-Realm")), "none")
end)

test("CharData: Overlay leitet alles ausser me/history/h2h an die Kontodaten weiter", function()
    local C = ns.CharData
    local db = { members = { X = { rating = 5 } }, settings = { badges = true } }
    local ch = C.Get(db, "A-R")
    local v = C.Overlay(db, ch)
    eq(v.me, ch.me); eq(v.members.X.rating, 5)
    v.settings.badges = false
    eq(db.settings.badges, false)
    v.newkey = 7
    eq(db.newkey, 7); eq(rawget(v, "newkey"), nil)
    v.me.wins = 2
    eq(ch.me.wins, 2)
end)

test("CharData: frischer Charakter ohne Altdaten startet mit 1000 und leerer Historie", function()
    local db = {}
    eq(ns.CharData.MigrateLegacy(db), false)
    local ch = ns.CharData.Get(db, "N-R")
    eq(ch.me.rating, 1000); eq(#ch.history, 0)
end)

test("Members: Resolve über Vornamen, Mehrwort-Teilnamen und Cache-Invalidierung", function()
    local M = ns.Members
    local members = { ["Anna Schmidt"] = {}, ["Bob Mueller"] = {}, ["Single"] = {} }
    M.Touch()
    eq(M.Resolve(members, "Anna Schmidt"), "Anna Schmidt")
    eq(M.Resolve(members, "Anna"), "Anna Schmidt")
    eq(M.Resolve(members, "Single"), "Single")
    eq(M.Resolve(members, "Nobody"), nil)
    members["Carl Zed"] = {}
    eq(M.Resolve(members, "Carl"), nil)       -- Index noch alt
    M.Touch()
    eq(M.Resolve(members, "Carl"), "Carl Zed")
    members["Anna Maria Long"] = {}
    M.Touch()
    eq(M.Resolve(members, "Anna Maria"), "Anna Maria Long")  -- Mehrwort-Teilname
    eq(M.Count(members), 5)
end)

test("Members: RelayChance 1 bis zum Zielwert, danach proportional", function()
    local M = ns.Members
    local members = {}
    M.Touch()
    eq(M.RelayChance(members, 30), 1)
    for i = 1, 29 do members["P" .. i] = {} end
    M.Touch()
    eq(M.RelayChance(members, 30), 1)
    for i = 30, 999 do members["P" .. i] = {} end
    M.Touch()
    local c = M.RelayChance(members, 30)
    truthy(c > 0.029 and c < 0.031, "Chance " .. c)
end)

test("Members: Build sortiert, filtert Ausgeschlossene und das eigene Ich, setzt Plätze; Prune entfernt Alte", function()
    local M = ns.Members
    local members = {
        A = { rating = 1100, wins = 1, losses = 0, lastSeen = 1000 },
        B = { rating = 1300, wins = 5, losses = 2, lastSeen = 1000 },
        Self = { rating = 900, wins = 0, losses = 0, lastSeen = 1000 },
        Bad = { rating = 2000, wins = 9, losses = 0, lastSeen = 1000 },
        Old = { rating = 1000, wins = 0, losses = 0, lastSeen = 1 },
    }
    local me = { name = "Me", rating = 1200, isMe = true }
    local list = M.Build(members, me, function(n) return n == "Self" end, function(n) return n == "Bad" end, 1000)
    local names = {}
    for _, e in ipairs(list) do names[#names + 1] = e.name end
    eq(table.concat(names, ","), "B,Me,A,Old")
    eq(list[2].pos, 2)
    eq(M.Prune(members, 100000, 3600), 5)   -- alle älter als eine Stunde bei now = 100000
    eq(next(members), nil)
end)

test("Members: Evict hält die Obergrenze, schützt Favoriten/Partner, wirft die ältesten zuerst raus", function()
    local M = ns.Members
    local old = M.CAP
    M.CAP = 10
    local members = {}
    for i = 1, 14 do members["P" .. i] = { lastSeen = i * 100 } end
    local keep = { P1 = true, P2 = true }    -- geschützt, obwohl am ältesten
    local removed = M.Evict(members, function(k) return keep[k] end)
    -- Ziel 90 % von 10 = 9: 14 -> 9, also 5 entfernt: P3..P7
    eq(removed, 5)
    truthy(members.P1 and members.P2, "Geschützte bleiben")
    eq(members.P3, nil); eq(members.P7, nil); truthy(members.P8, "P8 bleibt")
    eq(M.Evict(members, function() return false end), 0)  -- unter der Grenze: nichts
    M.CAP = old
end)

test("Members: ShouldAnnounce – kleine Netze alle, grosse Netze nur die Spitze; Relay bei Sättigung kleiner", function()
    local M = ns.Members
    local small = {}
    for i = 1, 100 do small["S" .. i] = { rating = 2000 } end
    M.Touch()
    eq(M.ShouldAnnounce(small, 800), true, "weniger als ANNOUNCE_TOP bekannt: alle melden sich")
    local big = {}
    for i = 1, 2000 do big["B" .. i] = { rating = 3000 - i } end -- Platz ANNOUNCE_TOP hat 3000 - 300 = 2700
    M.Touch()
    eq(M.ShouldAnnounce(big, 2699), false)
    eq(M.ShouldAnnounce(big, 2700), true)
    eq(M.ShouldAnnounce(big, 1200), false, "fester Schwellenwert gilt nicht mehr")
    local members = {}
    for i = 1, M.CAP do members["P" .. i] = {} end
    M.Touch()
    local c = M.RelayChance(members, 30)
    truthy(c < 30 / M.CAP, "bei Sättigung wird ein grösseres Netz angenommen: " .. c)
end)

test("CharData: won-Menge wird aus der Historie aufgebaut und bleibt nach dem Kürzen erhalten", function()
    local C = ns.CharData
    local db = {}
    local ch = C.Get(db, "A-R")
    ch.history[1] = { opponent = "X", won = true }
    ch.history[2] = { opponent = "Y", won = true, weight = 0 }      -- ohne Wertung
    ch.history[3] = { opponent = "Z", won = true, ranked = false }  -- Brawl
    ch.history[4] = { opponent = "W", won = false }
    ch.won = nil
    ch = C.Get(db, "A-R")
    eq(ns.Boost.DistinctWins(ch.history, ch.won), 1)
    -- Kürzen
    local h = {}
    for i = 1, 3200 do h[i] = { opponent = "O" .. i, time = i } end
    eq(C.TrimHistory(h), 700)
    eq(#h, 2500); eq(h[1].time, 701); eq(h[2500].time, 3200)
    eq(C.TrimHistory(h), 0)
    -- Überlay zeigt die won-Menge
    local view = C.Overlay(db, ch)
    eq(view.won, ch.won)
end)

test("Ban: Resolve räumt abgelaufene Sperrfristen und Melde-Zeitstempel auf", function()
    local s = ns.Ban.Ensure({})
    s.cool.X = 100
    s.cool.Y = 10 ^ 9
    s.lastReport.A = 100
    s.lastReport.B = 10 ^ 9
    ns.Ban.Resolve(s, 5000000)
    eq(s.cool.X, nil); truthy(s.cool.Y)
    eq(s.lastReport.A, nil); truthy(s.lastReport.B)
end)

test("DuelParse.CanPair: Zeitstempel des Duellendes entscheidet, nicht die Ankunft", function()
    local P = ns.DuelParse
    -- verzögerte Antwort (10 Minuten später eingetroffen), aber gleicher Duellzeitpunkt
    eq(P.CanPair({ ts = 1000, t = 5 }, { ts = 1003, t = 600 }), true)
    -- altes Duell aus früherer Runde (3 Minuten Abstand) gehört nicht dazu
    eq(P.CanPair({ ts = 1000, t = 5 }, { ts = 1180, t = 6 }), false)
    -- ohne Zeitstempel (alter Client): Ankunftsabstand
    eq(P.CanPair({ t = 5 }, { ts = 1000, t = 40 }), true)
    eq(P.CanPair({ t = 5 }, { t = 400 }), false)
    eq(P.CanPair(nil, { ts = 1, t = 1 }), false)
end)
