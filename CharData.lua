local _, ns = ...

-- Pro-Charakter-Daten (me, history, h2h) innerhalb der kontoweiten FightclubDB. Reine Logik, ohne WoW-API.
-- FightclubDB.chars[charKey] = { me, history, h2h }; alles andere (members, home, bans, settings) bleibt kontoweit.
-- Stände aus der Zeit vor der Trennung liegen in FightclubDB.legacy, bis ein Charakter sie mit /fc claim übernimmt.
local CharData = {}
ns.CharData = CharData

local function NewChar()
    return { me = { rating = 1000, wins = 0, losses = 0 }, history = {}, h2h = {} }
end

-- Liefert die Daten des Charakters (legt sie bei Bedarf an).
function CharData.Get(db, key)
    db.chars = db.chars or {}
    if not db.chars[key] then db.chars[key] = NewChar() end
    local ch = db.chars[key]
    ch.me = ch.me or { rating = 1000, wins = 0, losses = 0 }
    ch.history = ch.history or {}
    ch.h2h = ch.h2h or {}
    if not ch.won then
        -- Menge der Gegner mit gewertetem Sieg: einmalig aus der Historie aufbauen, danach fortschreiben
        ch.won = {}
        for _, e in ipairs(ch.history) do
            if e.won and e.ranked ~= false and (e.weight == nil or e.weight > 0) then ch.won[e.opponent] = true end
        end
    end
    return ch
end

local function HasStats(me, history)
    if not me then return false end
    return (me.wins or 0) > 0 or (me.losses or 0) > 0 or (me.bw or 0) > 0 or (me.bl or 0) > 0
        or (me.rating or 1000) ~= 1000 or (history ~= nil and #history > 0)
end

-- Verschiebt Altdaten (db.me / db.history / db.h2h auf Kontoebene) einmalig nach db.legacy.
-- Gibt true zurück, wenn dabei echte Statistiken gefunden wurden.
function CharData.MigrateLegacy(db)
    if db.legacyChecked then return db.legacy ~= nil end
    db.legacyChecked = true
    local found = HasStats(db.me, db.history)
    if found then
        db.legacy = { me = db.me, history = db.history or {}, h2h = db.h2h or {} }
    end
    db.me, db.history, db.h2h = nil, nil, nil
    return found
end

-- Frischer Charakter = noch keine Duelle und Startrating.
function CharData.IsFresh(ch)
    return not HasStats(ch.me, ch.history)
end

-- Übernimmt die Altdaten für diesen Charakter. Gibt ok, Grund zurück.
function CharData.Claim(db, key, force)
    if not db.legacy then return false, "none" end
    local ch = CharData.Get(db, key)
    if not force and not CharData.IsFresh(ch) then return false, "not fresh" end
    ch.me, ch.history, ch.h2h = db.legacy.me, db.legacy.history, db.legacy.h2h
    ch.won = nil -- wird beim nächsten Get() aus der übernommenen Historie neu aufgebaut
    db.legacy = nil
    return true
end

-- Sicht für den Rest des Addons: ns.db.me / history / h2h zeigen auf den Charakter, alles andere auf die Kontodaten.
function CharData.Overlay(db, ch)
    return setmetatable({ me = ch.me, history = ch.history, h2h = ch.h2h, won = ch.won }, { __index = db, __newindex = db })
end

-- Begrenzt die Historie: über max Einträgen werden die ältesten gelöscht, bis keep übrig sind (in place, da
-- ns.db.history auf diese Tabelle zeigt). Gibt die Zahl entfernter zurück.
CharData.HISTORY_MAX = 3000
CharData.HISTORY_KEEP = 2500

function CharData.TrimHistory(history, max, keep)
    max, keep = max or CharData.HISTORY_MAX, keep or CharData.HISTORY_KEEP
    local n = #history
    if n <= max then return 0 end
    local drop = n - keep
    for i = 1, keep do history[i] = history[i + drop] end
    for i = keep + 1, n do history[i] = nil end
    return drop
end
