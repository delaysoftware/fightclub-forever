-- Reiner Transportkern (NetCore.lua): Budget pro Prefix, Prioritäten, Drosselung, zuverlässige Zustellung.
local ns = {}
assert(loadfile("NetCore.lua"))("Fightclub", ns)
local C = ns.NetCore

local function Item(prefix, msg, prio) return { prefix = prefix, msg = msg, prio = prio } end

test("NetCore: Budget pro Prefix – Burst, dann Nachschub pro Sekunde", function()
    local q = C.NewQueue()
    local sent = {}
    for i = 1, 15 do C.Push(q, Item("FCg", "m" .. i, C.NORMAL), 0) end
    C.Pump(q, 0, function(it) sent[#sent + 1] = it.msg; return "ok" end)
    eq(#sent, C.BURST, "Burst")
    C.Pump(q, 2, function(it) sent[#sent + 1] = it.msg; return "ok" end)
    eq(#sent, C.BURST + 2, "zwei Sekunden Nachschub")
    eq(sent[1], "m1"); eq(sent[12], "m12")
end)

test("NetCore: getrennte Prefixe – voller Gossip-Prefix bremst Dringendes nicht", function()
    local q = C.NewQueue()
    local sent = {}
    for i = 1, 30 do C.Push(q, Item("FCg", "g" .. i, C.BULK), 0) end
    C.Pump(q, 0, function(it) sent[#sent + 1] = it.msg; return "ok" end)
    C.Push(q, Item("FCd", "urgent", C.URGENT), 0.1)
    C.Pump(q, 0.1, function(it) sent[#sent + 1] = it.msg; return "ok" end)
    eq(sent[#sent], "urgent")
end)

test("NetCore: höhere Priorität zuerst, BULK verfällt", function()
    local q = C.NewQueue()
    local sent = {}
    local function send(it) sent[#sent + 1] = it.msg; return "ok" end
    -- Budget aufbrauchen
    for i = 1, C.BURST do C.Push(q, Item("FCg", "x" .. i, C.NORMAL), 0) end
    C.Pump(q, 0, send)
    C.Push(q, Item("FCg", "bulk", C.BULK), 0)
    C.Push(q, Item("FCg", "normal", C.NORMAL), 0)
    C.Pump(q, 1, send)
    eq(sent[#sent], "normal", "NORMAL vor BULK")
    C.Pump(q, C.BULK_TTL + 5, send)
    eq(sent[#sent], "normal", "veraltetes BULK wird nicht mehr gesendet")
    eq(C.Size(q), 0)
    truthy(q.stats.dropped >= 1)
end)

test("NetCore: vom Client gedrosselte Nachricht bleibt in der Schlange und geht später raus", function()
    local q = C.NewQueue()
    local tries = 0
    local ok
    C.Push(q, Item("FCd", "res", C.URGENT), 0)
    local function send() tries = tries + 1; if tries <= 2 then return "throttle" end; ok = true; return "ok" end
    C.Pump(q, 0, send)
    eq(ok, nil); eq(C.Size(q), 1)
    C.Pump(q, 0.5, send)  -- Budget nach Drosselung leer: noch kein neuer Versuch
    eq(tries, 1)
    C.Pump(q, 1.1, send)
    C.Pump(q, 2.2, send)
    truthy(ok, "zugestellt"); eq(C.Size(q), 0); eq(q.stats.throttled, 2)
end)

test("NetCore: Chat-Sperre (hold) behält die Nachricht ohne Budget und ohne Drossel-Zähler", function()
    local q = C.NewQueue()
    local locked, sent = true, 0
    C.Push(q, Item("FCd", "res", C.URGENT), 0)
    local function send() if locked then return "hold" end; sent = sent + 1; return "ok" end
    for t = 0, 5 do C.Pump(q, t, send) end
    eq(sent, 0); eq(C.Size(q), 1, "bleibt in der Schlange"); eq(q.stats.throttled, 0); eq(q.stats.dropped, 0)
    locked = false
    C.Pump(q, 6, send)
    eq(sent, 1); eq(C.Size(q), 0)
end)

test("NetCore: Reliable wiederholt nach Plan bis Done, Zeitüberschreitung ruft onTimeout", function()
    local r = C.NewReliable()
    local sends, timedOut = 0, nil
    C.Track(r, "k", { send = function() sends = sends + 1 end, ttl = 10, onTimeout = function(key) timedOut = key end }, 0)
    eq(sends, 1, "sofort gesendet")
    C.Tick(r, 0.5); eq(sends, 2)
    C.Tick(r, 1.0); eq(sends, 2, "nächster Versuch erst nach 1 s")
    C.Tick(r, 1.5); eq(sends, 3)
    eq(C.Count(r, "k"), 1)
    eq(C.Done(r, "k"), true); eq(C.Done(r, "k"), false)
    C.Tick(r, 100); eq(sends, 3); eq(timedOut, nil)

    C.Track(r, "t", { send = function() end, ttl = 5, onTimeout = function(key) timedOut = key end }, 0)
    C.Tick(r, 6)
    eq(timedOut, "t"); eq(C.Count(r), 0)
end)
