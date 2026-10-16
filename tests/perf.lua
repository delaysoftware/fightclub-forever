-- Manueller Lasttest (nicht Teil von run.lua): lua tests/perf.lua [Mitgliederzahl]
local N = tonumber(arg and arg[1]) or 1000
local ns = dofile("tests/load.lua")
local M = ns.Members

local members = {}
for i = 1, N do
    members[("Vorname%d Nachname%d"):format(i, i)] = {
        rating = 800 + (i * 37) % 1000, wins = i % 50, losses = i % 40, level = 60, distinct = i % 12,
        bw = i % 9, bl = i % 7, lastSeen = os.time(),
    }
end
M.Touch()
local me = { name = "Ich", rating = 1000, isMe = true }
local function isSelf(name) return name == "Ich" end
local function isBanned() return false end

local function bench(label, reps, fn)
    local t0 = os.clock()
    for _ = 1, reps do fn() end
    local ms = (os.clock() - t0) * 1000 / reps
    print(("%-58s %8.3f ms"):format(label, ms))
    return ms
end

print(("Mitglieder: %d"):format(N))
bench("Liste bauen + sortieren + Prozentgrenzen (Members.Build)", 20, function()
    M.Build(members, me, isSelf, isBanned, os.time())
end)

-- Namenssuche über den Vornamen: neuer Index gegen die frühere lineare Suche
local names = {}
for i = 1, 200 do names[i] = ("Vorname%d"):format(i * (N // 200 + 1) % N + 1) end
bench("200 Namenssuchen per Vorname (Index)", 20, function()
    for i = 1, #names do M.Resolve(members, names[i]) end
end)
bench("200 Namenssuchen per Vorname (frühere lineare Suche)", 5, function()
    for i = 1, #names do
        local name = names[i]
        for key in pairs(members) do
            if key:sub(1, #name + 1) == name .. " " then break end
        end
    end
end)
bench("40 Plaketten x 4 Namen, unbekannte Spieler (Index)", 20, function()
    for p = 1, 40 do for k = 1, 4 do M.Resolve(members, "Fremder" .. p .. k) end end
end)
bench("40 Plaketten x 4 Namen, unbekannte Spieler (frühere Suche)", 5, function()
    for p = 1, 40 do for k = 1, 4 do
        local name = "Fremder" .. p .. k
        for key in pairs(members) do if key:sub(1, #name + 1) == name .. " " then break end end
    end end
end)
bench("RelayChance", 1000, function() M.RelayChance(members, 30) end)
print(("Relay-Chance bei %d Mitgliedern: %.3f (Ziel 30 Kopien pro Takt im Netz)"):format(N, M.RelayChance(members, 30)))

-- Kanal-HELLO: wie viele der N Spieler melden sich bei vollem Überblick im Kanal (Ziel: etwa ANNOUNCE_TOP, egal wie
-- gross N ist)? Jeder Spieler meldet sich alle 20-30 Minuten.
bench("Members.ShouldAnnounce (Rangliste sortieren)", 20, function() M.ShouldAnnounce(members, 1000) end)
local announcing = 0
for _, m in pairs(members) do
    if M.ShouldAnnounce(members, m.rating) then announcing = announcing + 1 end
end
print(("Kanal-HELLO: %d von %d Spielern melden sich (ANNOUNCE_TOP %d) -> ca. %d Nachrichten pro 10 Minuten"):format(
    announcing, N, M.ANNOUNCE_TOP, math.floor(announcing * 600 / 1500 + 0.5)))

-- Obergrenze: 6000 Mitglieder auf 90 % von 5000 zurückschneiden
local big = {}
for i = 1, 6000 do big[("N%d X%d"):format(i, i)] = { lastSeen = i } end
local t0 = os.clock()
local removed = M.Evict(big, function() return false end)
print(("Members.Evict: %d von 6000 entfernt in %.1f ms"):format(removed, (os.clock() - t0) * 1000))
