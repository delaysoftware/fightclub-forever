local _, ns = ...

-- Reine Logik: aus den Duell-Formatstrings des Clients (z. B. "%1$s has defeated %2$s in a duel.")
-- ein Lua-Muster bauen und aus einer Systemmeldung Sieger und Verlierer lesen.
-- Wichtig: Die Platzhalter-Nummern bestimmen die Rolle (1 = Sieger, 2 = Verlierer), nicht die Textreihenfolge
-- ("%2$s has fled from %1$s": der Verlierer steht zuerst im Text).
local P = {}
ns.DuelParse = P

local function Escape(t)
    return (t:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

function P.Compile(fmt)
    local parts, order, seq, pos = {}, {}, 0, 1
    while pos <= #fmt do
        local s1, e1, n = fmt:find("%%(%d)%$s", pos)
        local s2, e2 = fmt:find("%%s", pos)
        local s, e, idx
        if s1 and (not s2 or s1 <= s2) then
            s, e, idx = s1, e1, tonumber(n)
        elseif s2 then
            seq = seq + 1
            s, e, idx = s2, e2, seq
        end
        if not s then
            parts[#parts + 1] = Escape(fmt:sub(pos))
            break
        end
        parts[#parts + 1] = Escape(fmt:sub(pos, s - 1)) .. "(.+)"
        order[#order + 1] = idx
        pos = e + 1
    end
    return { pattern = "^" .. table.concat(parts) .. "$", order = order }
end

-- Gibt winner, loser zurück oder nil, wenn die Meldung nicht passt.
function P.Match(msg, compiled)
    local caps = { msg:match(compiled.pattern) }
    if #caps < 2 then return nil end
    local winner, loser
    for i, idx in ipairs(compiled.order) do
        if idx == 1 then winner = caps[i] elseif idx == 2 then loser = caps[i] end
    end
    if winner and loser then return winner, loser end
end

-- Englische Standardformate, falls der Client die Globals nicht (oder anders) bereitstellt.
P.DEFAULTS = {
    "%1$s has defeated %2$s in a duel.",
    "%2$s has fled from %1$s in a duel.",
    "%1$s has defeated %2$s in a duel",
    "%2$s has fled from %1$s in a duel",
}

-- Gehören zwei Ergebnismeldungen (meine / die des Gegners) zum selben Duell?
-- Beide Seiten stempeln ihre Meldung mit der Serverzeit des Duellendes (ts); Meldungen vom selben Duell liegen
-- wenige Sekunden auseinander, auch wenn eine Nachricht verzögert eintrifft. Fehlt ein Stempel (alter Client),
-- zählt die Ankunftszeit (t, in Sekunden).
P.PAIR_WINDOW = 45
P.ARRIVAL_WINDOW = 180

function P.CanPair(mine, theirs)
    if not (mine and theirs) then return false end
    if mine.ts and theirs.ts then
        return math.abs(mine.ts - theirs.ts) <= P.PAIR_WINDOW
    end
    return math.abs(mine.t - theirs.t) <= P.ARRIVAL_WINDOW
end
