local ns = dofile("tests/load.lua")
local Codec = ns.HomeCodec

local P = { proposer = "Anthony", mapID = 1429, x = 0.1234, y = 0.5, name = "Goldshire", startTime = 1000000 }

test("Codec: Proposal Round-Trip", function()
    local m = Codec.Decode(Codec.EncodeProposal(P))
    eq(m.kind, "PROPOSE")
    eq(m.p.proposer, "Anthony"); eq(m.p.mapID, 1429)
    eq(m.p.x, 0.1234); eq(m.p.y, 0.5)
    eq(m.p.name, "Goldshire"); eq(m.p.startTime, 1000000)
end)

test("Codec: Vote Round-Trip", function()
    local m = Codec.Decode(Codec.EncodeVote("Anthony-1000000", false, 1000050))
    eq(m.kind, "VOTE"); eq(m.id, "Anthony-1000000"); eq(m.yes, false); eq(m.ts, 1000050)
    eq(Codec.Decode(Codec.EncodeVote("a-1", true, 5)).yes, true)
end)

test("Codec: Current Round-Trip", function()
    local c = { epoch = 3, mapID = 1429, x = 0.25, y = 0.75, name = "Goldshire", since = 1086400 }
    local m = Codec.Decode(Codec.EncodeCurrent(c))
    eq(m.kind, "CUR"); eq(m.current.epoch, 3); eq(m.current.since, 1086400)
    eq(m.current.name, "Goldshire")
end)

test("Codec: Name wird von Pipe, Komma, Doppelpunkt und Steuerzeichen befreit und gekürzt", function()
    local p = { proposer = "A", mapID = 1, x = 0, y = 1, name = "Ab|c,d:e\nfghijklmnopqrstuvwxyz", startTime = 5 }
    local m = Codec.Decode(Codec.EncodeProposal(p))
    eq(m.p.name, "Abcdefghijklmnop") -- 16 Zeichen
end)

test("Codec: Votes werden in Teile ≤ 255 zerlegt und vollständig übertragen", function()
    local votes, times, longId = {}, {}, string.rep("x", 30) .. "-1000000"
    local prefix = string.rep("n", 20)
    for i = 1, 10 do votes[prefix .. i] = (i % 2 == 0); times[prefix .. i] = 1000000 + i end
    local parts = Codec.EncodeVotes(longId, votes, times)
    truthy(#parts >= 2, "sollte in mehrere Teile zerlegt werden")
    local seen, count = {}, 0
    for _, part in ipairs(parts) do
        truthy(#part <= 255, "Teil zu lang: " .. #part)
        local m = Codec.Decode(part)
        eq(m.kind, "VOTES"); eq(m.id, longId)
        for name, yes in pairs(m.votes) do seen[name] = yes; count = count + 1 end
    end
    eq(count, 10)
    eq(seen[prefix .. 2], true); eq(seen[prefix .. 1], false)
    local m1 = Codec.Decode(parts[1])
    for name in pairs(m1.votes) do truthy(m1.times[name] == times[name], "ts fehlt/falsch für " .. name) end
end)

test("Codec: Votes ohne Einträge ergibt keine Nachricht", function()
    eq(#Codec.EncodeVotes("a-1", {}), 0)
end)

test("Codec: feindliche/kaputte Eingaben ergeben nil und werfen nie", function()
    local bad = {
        "", "|", "PROPOSE", "PROPOSE|1|A", "PROPOSE|1|A|1|0.5|0.5|n",            -- zu wenige Felder
        "PROPOSE|1|A|1|0.5|0.5|n|5|extra",                                        -- zu viele Felder
        "PROPOSE|2|A|1|0.5|0.5|n|5",                                              -- falsche Version
        "PROPOSE|1|A|1|nan|0.5|n|5", "PROPOSE|1|A|1|inf|0.5|n|5",                 -- nan / inf
        "PROPOSE|1|A|1|1.5|0.5|n|5", "PROPOSE|1|A|1|-0.1|0.5|n|5",                -- ausserhalb 0..1
        "PROPOSE|1||1|0.5|0.5|n|5", "PROPOSE|1|A|0|0.5|0.5|n|5",                  -- leerer Name / mapID 0
        "PROPOSE|1|A|1.5|0.5|0.5|n|5", "PROPOSE|1|A|1|0.5|0.5|n|-5",              -- keine Ganzzahl / negativ
        "VOTE|1|a-1|X|5", "VOTE|1||Y|5", "VOTE|1|a-1|Y", "VOTE|1|a-1|Y|0", "VOTE|1|a-1|Y|x", -- kaputte Stimmen
        "VOTES|1|a-1|bob:X:5", "VOTES|1|a-1|bob:Y", "VOTES|1|a-1|bob:Y:x",
        "CUR|1|0|1|0.5|0.5|n|5", "CUR|1|x|1|0.5|0.5|n|5",                         -- epoch < 1 / kein Zahl
        "UNKNOWN|1|a", string.rep("A", 5000), string.rep("|", 300),
    }
    for _, text in ipairs(bad) do
        local ok, res = pcall(Codec.Decode, text)
        truthy(ok, "Decode warf Fehler bei: " .. text:sub(1, 40))
        eq(res, nil, "sollte nil sein: " .. text:sub(1, 40))
    end
end)

test("Codec: Zufallseingaben werfen nie", function()
    math.randomseed(42)
    local parts = { "PROPOSE", "VOTE", "VOTES", "CUR", "1", "|", "a", "0.5", "nan", "-1", ":", "," , "Y" }
    for _ = 1, 500 do
        local s = {}
        for i = 1, math.random(1, 10) do s[i] = parts[math.random(#parts)] end
        local ok = pcall(Codec.Decode, table.concat(s, math.random() < 0.7 and "|" or ""))
        truthy(ok)
    end
end)

test("Codec: Namen werden UTF-8-sicher gekürzt", function()
    local name = string.rep("a", 15) .. "\195\188x"
    local p = { proposer = "A", mapID = 1, x = 0, y = 1, name = name, startTime = 5 }
    eq(Codec.Decode(Codec.EncodeProposal(p)).p.name, string.rep("a", 15))
    local raw = "PROPOSE|1|A|1|0.0000|1.0000|" .. name .. "|5"
    eq(Codec.Decode(raw).p.name, string.rep("a", 15))
end)

test("Codec: zweiteilige Spielernamen (Vor- und Nachname) laufen durch PROPOSE, VOTE und VOTES", function()
    local p = Codec.Decode(Codec.EncodeProposal({ proposer = "Anna Schmidt", mapID = 1, x = 0.5, y = 0.5, name = "Ort", startTime = 1000000 }))
    eq(p.p.proposer, "Anna Schmidt")
    local id = "Anna Schmidt-1000000"
    eq(Codec.Decode(Codec.EncodeVote(id, true, 1000001)).id, id)
    local parts = Codec.EncodeVotes(id, { ["Anna Schmidt"] = true, ["Bob Mueller"] = false }, { ["Anna Schmidt"] = 1000001, ["Bob Mueller"] = 1000002 })
    local m = Codec.Decode(parts[1])
    eq(m.votes["Anna Schmidt"], true); eq(m.votes["Bob Mueller"], false)
end)
