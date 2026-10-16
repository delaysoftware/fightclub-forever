local _, ns = ...

-- Reiner Kern der Transportschicht (ohne WoW-API, testbar):
--  * Token-Bucket pro Prefix: der Client drosselt Addon-Nachrichten pro Prefix; was darüber hinausgeht, verwirft er
--    still. Deshalb senden wir nie schneller, als das Budget erlaubt.
--  * Warteschlange mit drei Prioritäten: URGENT (Duell-Ergebnisse, Beitrittsanfragen) vor NORMAL vor BULK (Gossip).
--    BULK-Nachrichten verfallen nach BULK_TTL, statt sich endlos zu stauen.
--  * Zuverlässige Zustellung: Eintrag wird nach SCHEDULE wiederholt, bis Done(key) oder die Lebensdauer abläuft.
local NetCore = {}
ns.NetCore = NetCore

NetCore.URGENT, NetCore.NORMAL, NetCore.BULK = 1, 2, 3
NetCore.BURST = 10   -- so viele Nachrichten pro Prefix auf einmal (Client-Drossel; im Forever-Client verifizieren)
NetCore.RATE = 1     -- Nachschub pro Sekunde und Prefix
NetCore.QUEUE_MAX = { 100, 200, 200 }
NetCore.BULK_TTL = 30
NetCore.MAX_THROTTLED = 20 -- so oft darf der Client eine Nachricht abweisen, bevor sie verworfen wird
NetCore.SCHEDULE = { 0.5, 1, 2, 4, 8, 15, 30 } -- Abstände zwischen Wiederholungen (danach immer der letzte Wert)

function NetCore.NewQueue()
    return { items = { {}, {}, {} }, buckets = {}, stats = { sent = 0, throttled = 0, dropped = 0, failed = 0 } }
end

local function Bucket(q, prefix, now)
    local b = q.buckets[prefix]
    if not b then
        b = { tokens = NetCore.BURST, t = now }
        q.buckets[prefix] = b
    end
    b.tokens = math.min(NetCore.BURST, b.tokens + (now - b.t) * NetCore.RATE)
    b.t = now
    return b
end

-- item = { prefix, msg, chan, target, prio }. Gibt false zurück, wenn die Schlange dieser Priorität voll ist.
function NetCore.Push(q, item, now)
    local prio = item.prio or NetCore.NORMAL
    item.prio = prio
    local list = q.items[prio]
    if #list >= NetCore.QUEUE_MAX[prio] then
        q.stats.dropped = q.stats.dropped + 1
        return false
    end
    item.t, item.throttled = now, 0
    list[#list + 1] = item
    return true
end

-- Sendet, was das Budget erlaubt. send(item) -> "ok" | "throttle" (später erneut) | "hold" (gesperrt, behalten,
-- ohne Zähler) | "fail" (verwerfen).
function NetCore.Pump(q, now, send)
    local st = q.stats
    for prio = 1, 3 do
        local list = q.items[prio]
        local i = 1
        while i <= #list do
            local item = list[i]
            if prio == NetCore.BULK and now - item.t > NetCore.BULK_TTL then
                table.remove(list, i)
                st.dropped = st.dropped + 1
            else
                local b = Bucket(q, item.prefix, now)
                if b.tokens >= 1 then
                    local r = send(item)
                    if r == "hold" then
                        -- Chat-Sperre: Nachricht bleibt in der Schlange (BULK verfällt nach BULK_TTL), kein Budget verbraucht
                        st.held = (st.held or 0) + 1
                        i = i + 1
                    elseif r == "throttle" then
                        b.tokens = 0 -- der Client sieht es enger als wir: bis zum Nachschub warten
                        st.throttled = st.throttled + 1
                        item.throttled = item.throttled + 1
                        if item.throttled > NetCore.MAX_THROTTLED then
                            table.remove(list, i)
                            st.dropped = st.dropped + 1
                        else
                            i = i + 1
                        end
                    else
                        b.tokens = b.tokens - 1
                        table.remove(list, i)
                        if r == "ok" then st.sent = st.sent + 1 else st.failed = st.failed + 1 end
                    end
                else
                    i = i + 1
                end
            end
        end
    end
end

function NetCore.Size(q)
    return #q.items[1] + #q.items[2] + #q.items[3]
end

----------------------------------------------------------------- Zuverlässige Zustellung
function NetCore.NewReliable()
    return { list = {} }
end

-- entry = { send = function(tries), ttl = Sekunden, onTimeout = function(key, entry) }. Sendet sofort das erste Mal.
function NetCore.Track(r, key, entry, now)
    entry.t0, entry.tries = now, 1
    entry.nextAt = now + NetCore.SCHEDULE[1]
    r.list[key] = entry
    entry.send(1)
end

function NetCore.Tick(r, now)
    local expired = {}
    local s = NetCore.SCHEDULE
    for key, e in pairs(r.list) do
        if now - e.t0 > (e.ttl or 600) then
            r.list[key] = nil
            expired[#expired + 1] = { key, e }
        elseif now >= e.nextAt then
            e.tries = e.tries + 1
            e.nextAt = now + s[math.min(e.tries, #s)]
            e.send(e.tries)
        end
    end
    for _, x in ipairs(expired) do
        if x[2].onTimeout then x[2].onTimeout(x[1], x[2]) end
    end
end

-- Zustellung bestätigt: nicht mehr wiederholen. Gibt true zurück, wenn der Eintrag offen war.
function NetCore.Done(r, key)
    local had = r.list[key] ~= nil
    r.list[key] = nil
    return had
end

function NetCore.Count(r, keyPrefix)
    local n = 0
    for key in pairs(r.list) do
        if not keyPrefix or key:sub(1, #keyPrefix) == keyPrefix then n = n + 1 end
    end
    return n
end
