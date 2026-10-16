local _, ns = ...

-- Reine Logik für grosse Mitgliederzahlen (ohne WoW-API): schnelle Namenssuche und die sortierte Liste.
-- Bei 1000+ Mitgliedern darf weder jede Namenssuche alle durchgehen noch jede Nachricht die Liste neu sortieren.
local Members = {}
ns.Members = Members

-- ---------------------------------------------------------------- Namenssuche
-- Systemmeldungen und Tooltips nennen evtl. nur den Vornamen, Addon-Nachrichten den vollen Namen. Der Index bildet
-- "erstes Wort" -> Schlüssel ab; er wird nur neu gebaut, wenn sich die Zahl/Zusammensetzung der Mitglieder ändert.
local index, indexFor, indexRev = nil, nil, -1
Members.rev = 0 -- bei jedem Hinzufügen/Entfernen eines Mitglieds hochzählen

function Members.Touch() Members.rev = Members.rev + 1 end

local function Index(members)
    if index and indexFor == members and indexRev == Members.rev then return index end
    index = {}
    for key in pairs(members) do
        local first = key:match("^(%S+) ")
        if first and not index[first] then index[first] = key end
    end
    indexFor, indexRev = members, Members.rev
    return index
end

-- Gibt den Mitgliedsschlüssel zu name zurück (exakt oder über den Vornamen) oder nil.
function Members.Resolve(members, name)
    if members[name] then return name end
    if name:find(" ", 1, true) then
        -- Teilname aus mehreren Wörtern: selten, deshalb einfach durchsuchen
        local prefix = name .. " "
        for key in pairs(members) do
            if key:sub(1, #prefix) == prefix then return key end
        end
        return nil
    end
    return Index(members)[name]
end

-- Grenzen für sehr grosse Netze (Forever hat keine Realms: im Extremfall teilen sich alle Spieler einen Kanal).
Members.CAP = 5000          -- höchstens so viele Mitglieder werden gespeichert
Members.ANNOUNCE_TOP = 300  -- so viele Spieler melden sich (ungefähr) im Kanal, egal wie gross das Netz ist

-- Soll dieser Spieler seinen Stand in den Kanal senden? Solange man weniger als ANNOUNCE_TOP Mitglieder kennt, ja.
-- Danach nur, wer in der eigenen Liste unter den besten ANNOUNCE_TOP liegt; alle anderen bleiben lokal (Gilde, Gruppe,
-- Duellpartner, Begegnungen). So bleibt die Kanallast etwa konstant, auch bei 100.000 Spielern.
function Members.ShouldAnnounce(members, rating)
    if Members.Count(members) < Members.ANNOUNCE_TOP then return true end
    local r = {}
    for _, m in pairs(members) do r[#r + 1] = m.rating or 0 end
    table.sort(r, function(a, b) return a > b end)
    return rating >= r[Members.ANNOUNCE_TOP]
end

-- Wirft die am längsten nicht gesehenen, nicht geschützten Mitglieder hinaus, sobald CAP überschritten ist
-- (bis auf 90 % von CAP). protected(name) -> true schützt einen Eintrag. Gibt die Zahl entfernter zurück.
function Members.Evict(members, protected)
    local total, cands = 0, {}
    for key, m in pairs(members) do
        total = total + 1
        if not protected(key) then cands[#cands + 1] = { key = key, seen = m.lastSeen or 0 } end
    end
    if total <= Members.CAP then return 0 end
    table.sort(cands, function(a, b)
        if a.seen ~= b.seen then return a.seen < b.seen end
        return a.key < b.key
    end)
    local target, removed = math.floor(Members.CAP * 0.9), 0
    for _, c in ipairs(cands) do
        if total - removed <= target then break end
        members[c.key] = nil
        removed = removed + 1
    end
    if removed > 0 then Members.Touch() end
    return removed
end

local countRev, count = -1, 0
-- Zahl der Mitglieder (zwischengespeichert, wird bei Touch() neu gezählt).
function Members.Count(members)
    if countRev ~= Members.rev then
        count = 0
        for _ in pairs(members) do count = count + 1 end
        countRev = Members.rev
    end
    return count
end

-- Wahrscheinlichkeit, mit der ein Client eine Zustands-Nachricht weiterverbreitet, damit im ganzen Netz pro Takt
-- etwa "target" Kopien umlaufen (statt einer pro Client). Bis zu "target" Mitgliedern verbreitet jeder (Chance 1).
function Members.RelayChance(members, target)
    local n = Members.Count(members) + 1
    -- An der Obergrenze kennt man nur einen Teil des Netzes: von einem viel grösseren ausgehen
    if n >= Members.CAP * 0.9 then n = n * 20 end
    return math.min(1, target / n)
end

-- ---------------------------------------------------------------- Liste
-- me: Eintrag des eigenen Charakters. isSelf(name)/isBanned(name): Prüffunktionen. Gibt die nach Rating sortierte
-- Liste (mit e.pos) und die Prozentgrenzen zurück.
function Members.Build(members, me, isSelf, isBanned, now)
    local list = { me }
    for name, m in pairs(members) do
        if not isBanned(name) and not isSelf(name) then
            list[#list + 1] = {
                name = name, rating = m.rating, wins = m.wins, losses = m.losses, level = m.level,
                distinct = m.distinct or 0, bw = m.bw or 0, bl = m.bl or 0, lastSeen = m.lastSeen,
            }
        end
    end
    table.sort(list, function(a, b)
        if a.rating ~= b.rating then return a.rating > b.rating end
        return a.name < b.name
    end)
    for i, e in ipairs(list) do e.pos = i end
    return list, ns.ComputeCutoffs(list, now)
end

-- Entfernt Mitglieder, die länger als maxAge Sekunden nicht gesehen wurden. Gibt die Zahl entfernter zurück.
function Members.Prune(members, now, maxAge)
    local dead = {}
    for key, m in pairs(members) do
        if m.lastSeen and now - m.lastSeen > maxAge then dead[#dead + 1] = key end
    end
    for _, key in ipairs(dead) do members[key] = nil end
    if #dead > 0 then Members.Touch() end
    return #dead
end
