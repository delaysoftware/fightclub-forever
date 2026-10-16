-- Simulation: zwei Clients (Comm.lua + Duel.lua) tauschen Duellergebnisse über einen verlustbehafteten Bus aus.
-- Prüft, dass beide Seiten das Duell am Ende genau einmal zählen, auch wenn Nachrichten verloren gehen oder spät kommen.
local T = 0          -- simulierte Zeit in Sekunden
local bus = {}       -- ausstehende Zustellungen
local clients = {}

local function NewClient(name, short)
    local ns = { commands = {}, msgHandlers = {} }
    local env = setmetatable({}, { __index = _G })
    local handlers, timers = {}, {}
    local self = { name = name, short = short, ns = ns, handlers = handlers, timers = timers }

    env.GetTime = function() return T end
    env.time = function() return 1000000000 + math.floor(T) end
    env.GetServerTime = env.time
    env.UnitLevel = function() return 5 end
    env.UnitName = function() return short end
    env.Ambiguate = function(n) return n end
    env.IsInGuild = function() return false end
    env.IsInRaid = function() return false end
    env.IsInGroup = function() return false end
    env.tostringall = function(...) return ... end
    env.strsplit = function(sep, s)
        local t, pos = {}, 1
        while true do
            local i = s:find(sep, pos, true)
            if not i then t[#t + 1] = s:sub(pos); break end
            t[#t + 1] = s:sub(pos, i - 1); pos = i + 1
        end
        return table.unpack(t)
    end
    env.C_Timer = {
        After = function(d, fn) timers[#timers + 1] = { at = T + d, fn = fn } end,
        NewTicker = function(iv, fn) timers[#timers + 1] = { at = T + iv, fn = fn, every = iv } end,
    }
    env.GetChannelName = function() return 1 end
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() end,
        SendAddonMessage = function(prefix, msg, channel, target)
            if self.throttle and self.throttle(prefix, msg) then return 3 end -- AddonMessageThrottle
            self.send(msg, channel, target, prefix)
        end,
    }
    env.FightclubDB = { members = {}, home = {}, bans = {}, settings = {} }

    ns.RegisterEvent = function(ev, fn) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], fn) end
    ns.Print = function(...) end
    ns.IsSelf = function(n) return n == name or n == short end
    ns.IsBanned = function() return false end
    ns.IsFavorite = function() return false end
    ns.RefreshBoard = function() end
    ns.InvalidateEntries = function() end
    ns.BrawlSeries = function() return 0, 0 end

    local function load(f) assert(loadfile(f, "t", env))("Fightclub", ns) end
    for _, f in ipairs({ "CharData.lua", "Home.lua", "HomeCodec.lua", "Rating.lua", "Members.lua", "Boost.lua", "DuelParse.lua",
        "NetCore.lua", "Net.lua" }) do
        load(f)
    end
    local ch = ns.CharData.Get(env.FightclubDB, short)
    ns.db = ns.CharData.Overlay(env.FightclubDB, ch)
    load("Comm.lua")
    load("Duel.lua")
    ns.Allowed = function() return true end
    ns.DisplayName = function() return name end
    self.printed = {}
    ns.Print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        self.printed[#self.printed + 1] = table.concat(parts, " ")
    end

    function self.fire(ev, ...) for _, fn in ipairs(handlers[ev] or {}) do fn(...) end end
    function self.deliver(from, text, dist, prefix) self.fire("CHAT_MSG_ADDON", prefix or "FCd", text, dist, from) end
    return self
end

-- Bus: drop(from, to, text, attempt) -> true = Nachricht geht verloren; delay in Sekunden
local function Connect(a, b, opts)
    opts = opts or {}
    local function sender(from, to)
        return function(msg, channel, target, prefix)
            if channel == "WHISPER" and target ~= to.name and target ~= to.short then return end
            local n = (opts.count or 0) + 1
            opts.count = n
            if opts.drop and opts.drop(from.name, msg, channel, n) then return end
            bus[#bus + 1] = { at = T + (opts.delay and opts.delay(msg, channel, n) or 0.2), to = to, from = from.name, msg = msg,
                ch = channel, prefix = prefix }
        end
    end
    a.send = sender(a, b)
    b.send = sender(b, a)
end

local function Step(dt)
    T = T + dt
    local due = {}
    for i = #bus, 1, -1 do
        if bus[i].at <= T then due[#due + 1] = table.remove(bus, i) end
    end
    table.sort(due, function(x, y) return x.at < y.at end)
    for _, m in ipairs(due) do m.to.deliver(m.from, m.msg, m.ch, m.prefix) end
    for _, c in ipairs(clients) do
        for i = #c.timers, 1, -1 do
            local t = c.timers[i]
            if t and t.at <= T then
                if t.every then t.at = T + t.every else table.remove(c.timers, i) end
                t.fn()
            end
        end
    end
end

local function Setup(opts)
    T, bus, clients = 0, {}, {}
    local a = NewClient("Omi Raffaello", "Omi")
    local b = NewClient("Dasisch Entest", "Dasisch")
    clients = { a, b }
    Connect(a, b, opts)
    a.fire("PLAYER_LOGIN"); b.fire("PLAYER_LOGIN")
    if opts and opts.strangers then return a, b end
    -- gegenseitig bekannt machen (HELLO)
    a.deliver("Dasisch Entest", "HELLO|1|1000|0|0|5|0|0|0", "WHISPER")
    b.deliver("Omi Raffaello", "HELLO|1|1000|0|0|5|0|0|0", "WHISPER")
    return a, b
end

-- A gewinnt gegen B; beide Clients lesen dieselbe Systemmeldung
local function Duel(a, b)
    local msg = "Omi Raffaello has defeated Dasisch Entest in a duel."
    a.fire("CHAT_MSG_SYSTEM", msg)
    b.fire("CHAT_MSG_SYSTEM", msg)
end

local function Run(seconds)
    for _ = 1, math.floor(seconds / 0.5) do Step(0.5) end
end

local function Counts(c)
    local me = c.ns.db.me
    return me.wins + me.losses, me.wins, me.losses, #c.ns.db.history
end

test("Sim: ohne Verlust zählen beide Seiten das Duell genau einmal", function()
    local a, b = Setup()
    Duel(a, b)
    Run(30)
    local an, aw, al = Counts(a)
    local bn, bw, bl = Counts(b)
    eq(an, 1); eq(aw, 1); eq(bn, 1); eq(bl, 1)
    eq(#a.ns.db.history, 1); eq(#b.ns.db.history, 1)
    eq(a.ns.PendingResults(), 0); eq(b.ns.PendingResults(), 0)
end)

test("Sim: Whisper-Weg vollständig tot – Kanal als Ausweichweg reicht", function()
    local a, b = Setup({ drop = function(_, _, channel) return channel == "WHISPER" end })
    Duel(a, b)
    Run(120)
    local an, _, _ = Counts(a)
    local bn, _, _ = Counts(b)
    eq(an, 1); eq(bn, 1)
end)

test("Sim: erste Nachrichten gehen verloren (A->B), Wiederholungen sorgen für gleichen Stand", function()
    -- Alles, was A in den ersten 20 Sekunden an B schickt, geht verloren; B->A kommt an.
    local a, b = Setup({ drop = function(from) return from == "Omi Raffaello" and T < 20 end })
    Duel(a, b)
    Run(120)
    local an = Counts(a)
    local bn = Counts(b)
    eq(an, 1, "A zählt"); eq(bn, 1, "B zählt")
    eq(#a.ns.db.history, 1); eq(#b.ns.db.history, 1)
end)

test("Sim: verspätete Zustellung (90 s) wird trotzdem gewertet, ohne Doppelzählung", function()
    local a, b = Setup({ delay = function() return 90 end })
    Duel(a, b)
    Run(400)
    eq((Counts(a)), 1); eq((Counts(b)), 1)
    eq(#a.ns.db.history, 1); eq(#b.ns.db.history, 1)
end)

test("Sim: zufälliger Verlust (40 %) in 60 Läufen – beide Seiten immer gleicher Stand, nie doppelt", function()
    local seed = 12345
    local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
    local bad = 0
    for run = 1, 60 do
        local a, b = Setup({ drop = function() return rnd() < 0.4 end, delay = function() return rnd() * 5 end })
        Duel(a, b)
        Run(600)
        local an, bn = (Counts(a)), (Counts(b))
        if an ~= bn or an > 1 or #a.ns.db.history ~= #b.ns.db.history then bad = bad + 1 end
    end
    eq(bad, 0, "Läufe mit unterschiedlichem oder doppeltem Stand")
end)

test("Sim: zwei Duelle kurz nacheinander gehen nicht verloren", function()
    local a, b = Setup({ delay = function() return 2 end })
    Duel(a, b)
    Run(5)
    Duel(a, b)
    Run(120)
    eq((Counts(a)), 2); eq((Counts(b)), 2)
end)

test("Sim: Duplikat desselben Ergebnisses (Wiederholung) wird nicht doppelt gezählt", function()
    local a, b = Setup()
    local sentByA = {}
    local origSend = a.send
    a.send = function(msg, channel, target)
        if msg:sub(1, 4) == "RES|" then sentByA[#sentByA + 1] = msg end
        origSend(msg, channel, target)
    end
    Duel(a, b)
    Run(20)
    eq((Counts(b)), 1)
    truthy(#sentByA >= 1, "A hat ein RES gesendet")
    -- dasselbe RES kommt später noch einmal bei B an (z. B. verspätete Wiederholung)
    for _ = 1, 3 do b.deliver("Omi Raffaello", sentByA[1], "WHISPER") end
    Run(20)
    eq((Counts(b)), 1)
    eq(#b.ns.db.history, 1)
end)

test("Sim: Duell zählt sofort vorläufig und wird nach der Bestätigung endgültig", function()
    local a, b = Setup()
    Duel(a, b)
    -- ohne dass eine Zeit vergangen ist: sofort vorläufig verbucht
    eq(a.ns.db.me.wins, 1); eq(a.ns.db.me.rating, 1016)
    truthy(a.ns.db.history[1].pending, "als vorläufig markiert")
    eq(b.ns.db.me.losses, 1)
    Run(20)
    eq(a.ns.db.history[1].pending, nil); eq(b.ns.db.history[1].pending, nil)
    eq(a.ns.db.me.wins, 1); eq(a.ns.db.me.rating, 1016)
    eq(b.ns.db.me.losses, 1)
end)

test("Sim: ohne Bestätigung wird das vorläufige Duell nach 10 Minuten zurückgenommen", function()
    local a, b = Setup({ drop = function() return true end })  -- gar keine Nachricht kommt an
    Duel(a, b)
    eq(a.ns.db.me.wins, 1)
    Run(300)
    eq(a.ns.db.me.wins, 1, "nach 5 Minuten noch vorläufig da")
    Run(400)
    eq(a.ns.db.me.wins, 0); eq(a.ns.db.me.rating, 1000); eq(#a.ns.db.history, 0)
    eq(b.ns.db.me.losses, 0); eq(#b.ns.db.history, 0)
    eq(next(a.ns.db.won), nil, "Gegnermenge wieder leer")
end)

test("Sim: widersprüchliche Ergebnisse (beide W) werden beide zurückgenommen", function()
    local a, b = Setup()
    a.fire("CHAT_MSG_SYSTEM", "Omi Raffaello has defeated Dasisch Entest in a duel.")
    b.fire("CHAT_MSG_SYSTEM", "Dasisch Entest has defeated Omi Raffaello in a duel.")
    Run(30)
    eq(a.ns.db.me.wins, 0); eq(b.ns.db.me.wins, 0)
    eq(#a.ns.db.history, 0); eq(#b.ns.db.history, 0)
    eq(a.ns.db.me.rating, 1000); eq(b.ns.db.me.rating, 1000)
end)

test("Sim: A meldet Brawl, B hat die Ankündigung verpasst – beide enden als Brawl", function()
    local a, b = Setup({ drop = function(_, msg) return msg:sub(1, 5) == "DUEL|" end })
    a.ns.AnnounceDuelMode("Dasisch Entest", "U")
    Duel(a, b)
    Run(30)
    eq(a.ns.db.me.bw, 1); eq(a.ns.db.me.rating, 1000)
    eq(b.ns.db.me.bl, 1); eq(b.ns.db.me.rating, 1000); eq(b.ns.db.me.losses, 0)
    eq(#b.ns.db.history, 1); eq(b.ns.db.history[1].ranked, false)
    eq(a.ns.db.history[1].pending, nil); eq(b.ns.db.history[1].pending, nil)
end)

test("Sim: ohne Verlust ist das Duell nach höchstens 1 Sekunde auf beiden Seiten bestätigt", function()
    local a, b = Setup()
    Duel(a, b)
    Run(1)
    eq(a.ns.db.history[1].pending, nil, "A bestätigt"); eq(b.ns.db.history[1].pending, nil, "B bestätigt")
    eq(a.ns.PendingResults(), 0); eq(b.ns.PendingResults(), 0)
end)

test("Sim: Gegner kennen sich vorher nicht (kein HELLO) – Duell zählt trotzdem auf beiden Seiten, schnell", function()
    local a, b = Setup({ strangers = true })
    Duel(a, b)
    eq(a.ns.db.me.wins, 0, "unbekannter Gegner: nicht vorläufig verbucht")
    Run(3)
    eq((Counts(a)), 1); eq((Counts(b)), 1)
    eq(a.ns.db.me.wins, 1); eq(b.ns.db.me.losses, 1)
    truthy(a.ns.db.members["Dasisch Entest"], "B ist jetzt Mitglied bei A")
    truthy(b.ns.db.members["Omi Raffaello"], "A ist jetzt Mitglied bei B")
    Run(200)
    eq((Counts(a)), 1); eq((Counts(b)), 1)
end)

test("Sim: unbekannter Gegner, Systemmeldung nennt nur Vornamen – Ergebnis wird dem vollen Namen zugeordnet", function()
    local a, b = Setup({ strangers = true })
    a.fire("CHAT_MSG_SYSTEM", "Omi has defeated Dasisch in a duel.")
    b.fire("CHAT_MSG_SYSTEM", "Omi has defeated Dasisch in a duel.")
    Run(10)
    eq(a.ns.db.me.wins, 1); eq(b.ns.db.me.losses, 1)
    eq(a.ns.db.history[1].opponent, "Dasisch Entest"); eq(b.ns.db.history[1].opponent, "Omi Raffaello")
    Run(200)
    eq((Counts(a)), 1); eq((Counts(b)), 1)
end)

test("Sim: Client drosselt die ersten Nachrichten – sie werden nachgesendet statt verloren", function()
    local a, b = Setup()
    local n = 0
    a.throttle = function() n = n + 1; return n <= 5 end
    Duel(a, b)
    Run(20)
    eq((Counts(a)), 1); eq((Counts(b)), 1)
    eq(a.ns.db.history[1].pending, nil); eq(b.ns.db.history[1].pending, nil)
    local _, throttled = a.ns.Net.Stats()
    truthy(throttled >= 1, "Drosselung gezählt")
end)

test("Sim: 30 % Verlust – Bestätigung im Schnitt nach wenigen Sekunden", function()
    local seed = 777
    local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
    local total, runs = 0, 40
    for _ = 1, runs do
        local a, b = Setup({ drop = function() return rnd() < 0.3 end })
        Duel(a, b)
        local t0 = T
        while T - t0 < 120 and (a.ns.db.history[1].pending or b.ns.db.history[1].pending) do Step(0.5) end
        total = total + (T - t0)
    end
    if os.getenv("FC_VERBOSE") then print(("  mittlere Bestätigungszeit bei 30 %% Verlust: %.1f s"):format(total / runs)) end
    truthy(total / runs <= 5, ("mittlere Zeit bis zur Bestätigung %.1f s"):format(total / runs))
end)
