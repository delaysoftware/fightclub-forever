local _, ns = ...
local Ban, Codec = ns.Ban, ns.BanCodec

local STATE_INTERVAL = 600
local REASONS = {
    invalid = "invalid data",
    clock = "clock differs too much",
    expired = "case already expired",
    self = "you cannot report yourself",
    ["not eligible"] = "not eligible (needs wins against 3 different opponents)",
    banned = "already excluded",
    ["unknown target"] = "unknown player (not a known Fightclub member)",
    ["target cooldown"] = "this player was recently cleared – wait 7 days",
    ["not banned"] = "this player is not excluded",
    ["report cooldown"] = "you can open one case every 24 hours",
    ["few voters"] = "not enough eligible voters yet (min. 5)",
    duplicate = "case already exists",
    open = "an earlier case against this player is already running",
    ["no case"] = "no matching case open",
    closed = "vote has ended",
    target = "you cannot vote on your own case",
}

local function State() return Ban.Ensure(ns.db.bans) end
local function MyName() return ns.DisplayName("player") end
local function Refresh() if ns.RefreshBoard then ns.RefreshBoard() end end

function ns.IsBanned(name)
    return ns.db ~= nil and Ban.IsBanned(State(), name, time())
end

-- Findet in "Vorname Nachname Grund..." den Spielernamen (längster Treffer) und liefert (name, rest).
local function MatchName(text, names)
    local low, best = text:lower(), nil
    for _, n in ipairs(names) do
        local l = n:lower()
        if (low == l or low:sub(1, #l + 1) == l .. " ") and (not best or #n > #best) then best = n end
    end
    if best then return best, text:sub(#best + 2) end
    local tok = low:match("^(%S+)")
    if not tok then return nil end
    local found
    for _, n in ipairs(names) do
        local l = n:lower()
        if l:sub(1, #tok + 1) == tok .. " " then
            if found then return nil end -- mehrdeutig
            found = n
        end
    end
    if found then return found, text:sub(#tok + 2) end
end

ns.MatchName = MatchName

local function Names(kind)
    local out = {}
    if kind == "ban" then
        for _, e in ipairs(ns.BuildEntries()) do if not e.isMe then out[#out + 1] = e.name end end
    else
        for n in pairs(State().banned) do out[#out + 1] = n end
    end
    return out
end

local function Open(kind, rest)
    local target, reason = MatchName(rest, Names(kind))
    if not target then
        ns.Print(kind == "ban" and "Usage: /fc report <player> <reason>" or "Usage: /fc lift <excluded player>")
        return
    end
    reason = (reason or ""):gsub("^%s+", "")
    if kind == "ban" and #reason < 3 then
        -- Ohne Grund: Formular im Bans-Tab mit dem Namen vorausgefüllt öffnen.
        if ns.BanPrefill then ns.BanPrefill(target) else ns.Print("Please give a short reason: /fc report <player> <reason>") end
        return
    end
    local now = time()
    local c = { kind = kind, reporter = MyName(), target = target, reason = reason, startTime = now }
    local ok, why = Ban.Open(State(), ns.BuildEntries(), c, now)
    if not ok then ns.Print("Case rejected:", REASONS[why] or why); return end
    local case = State().cases[target]
    ns.Broadcast(Codec.EncodeCase(case))
    ns.Print(kind == "ban" and "Exclusion vote opened against" or "Lift vote opened for", target, "(24 h)")
    Refresh()
end

local function FindOpenCase(nameText)
    local s = State()
    local list = {}
    for _, c in pairs(s.cases) do list[#list + 1] = c end
    if nameText and nameText ~= "" then
        local names = {}
        for _, c in ipairs(list) do names[#names + 1] = c.target end
        local target = MatchName(nameText, names)
        return target and s.cases[target]
    end
    if #list == 1 then return list[1] end
    return nil, #list
end

function ns.BanCastVote(yes, nameText)
    local case, n = FindOpenCase(nameText)
    if not case then
        ns.Print(n and n > 1 and "Several cases are open – add the player: /fc ban yes|no <player>" or "No matching case open.")
        return
    end
    local ts = time()
    local ok, why = Ban.Vote(State(), ns.BuildEntries(), MyName(), case.id, yes, ts, ts)
    if not ok then ns.Print("Vote rejected:", REASONS[why] or why); return end
    ns.Broadcast(Codec.EncodeVote(case.id, yes, ts))
    ns.Print("Vote cast on", case.target .. ":", yes and "Yes" or "No")
    Refresh()
end

function ns.BanResolveNow()
    local results = Ban.Resolve(State(), time())
    for _, r in ipairs(results) do
        if r.kind == "ban" then
            ns.Print(r.passed and (r.target .. " was excluded from the Fightclub for 30 days.")
                or ("The exclusion vote against " .. r.target .. " was rejected."))
        else
            ns.Print(r.passed and (r.target .. " was readmitted to the Fightclub.")
                or ("The vote to lift the exclusion of " .. r.target .. " was rejected."))
        end
    end
    if #results > 0 then
        if ns.InvalidateEntries then ns.InvalidateEntries() end
        Refresh()
    end
end

-- Bei grossen Netzen verbreitet nur ein Teil der Clients Anträge, Stimmenlisten und Sperren weiter (sonst schickt jeder
-- Client alle 10 Minuten die komplette Liste). Die eigene Stimme geht immer raus.
local RELAY_TARGET = 60

function ns.BanBroadcastState()
    local s = State()
    local me = MyName()
    local relay = math.random() < ns.Members.RelayChance(ns.db.members, RELAY_TARGET)
    local function Q(msg) ns.Net.Broadcast(msg, ns.Net.BULK) end
    for _, case in pairs(s.cases) do
        local mv, mt = case.votes[me], case.voteTimes[me]
        if not relay and mv ~= nil and mt then Q(Codec.EncodeVote(case.id, mv, mt)) end -- sonst steckt sie in der Liste
        if relay then
            Q(Codec.EncodeCase(case))
            for _, part in ipairs(Codec.EncodeVotes(case.id, case.votes, case.voteTimes)) do Q(part) end
        end
    end
    if relay then
        for name, b in pairs(s.banned) do Q(Codec.EncodeBan(name, b.since, b.untilT)) end
    end
end

local function OnMessage(sender, text)
    if not ns.db.members[sender] or ns.IsBanned(sender) or not ns.Allowed(sender) then return end
    local msg = Codec.Decode(text)
    if not msg then return end
    local s, entries, now = State(), ns.BuildEntries(), time()
    local me = MyName()

    if msg.kind == "BCASE" then
        local c = msg.c
        if sender ~= c.reporter and not Ban.IsVoter(s, entries, sender, now) then return end
        local had = s.cases[c.target] and s.cases[c.target].id
        local ok = Ban.Open(s, entries, c, now)
        local case = s.cases[c.target]
        if ok and case and case.id ~= had then
            if c.target == me then
                ns.Print("A vote to exclude you from the Fightclub was opened by", c.reporter)
            elseif c.kind == "ban" then
                ns.Print(("Exclusion vote: %s (by %s: %s) – /fc ban yes|no %s"):format(c.target, c.reporter, case.reason, c.target))
            else
                ns.Print(("Vote to readmit %s – /fc ban yes|no %s"):format(c.target, c.target))
            end
        end
    elseif msg.kind == "BVOTE" then
        Ban.Vote(s, entries, sender, msg.id, msg.yes, now, msg.ts)
    elseif msg.kind == "BVOTES" then
        if not Ban.IsVoter(s, entries, sender, now) then return end
        for voter, yes in pairs(msg.votes) do
            if voter ~= me then Ban.Vote(s, entries, voter, msg.id, yes, now, msg.times[voter]) end
        end
    elseif msg.kind == "BBAN" then
        if Ban.Announce(s, entries, sender, msg.target, msg.since, msg.untilT, now) then
            if ns.InvalidateEntries then ns.InvalidateEntries() end
            ns.Print(msg.target, msg.target == me and "(you)" or "", "is excluded from the Fightclub.")
        end
    end
    ns.BanResolveNow()
    Refresh()
end

for _, kind in ipairs({ "BCASE", "BVOTE", "BVOTES", "BBAN" }) do
    ns.msgHandlers[kind] = OnMessage
end

ns.RegisterEvent("PLAYER_LOGIN", function()
    C_Timer.After(14 + math.random(0, 50), function()
        ns.BanBroadcastState()
        local b = State().banned[MyName()]
        if b and b.untilT > time() then
            ns.Print("You are excluded from the Fightclub until", date("%d.%m.%Y", b.untilT))
        end
        ns.BanResolveNow()
    end)
    C_Timer.After(math.random(0, 120), function() C_Timer.NewTicker(STATE_INTERVAL, ns.BanBroadcastState) end)
    C_Timer.NewTicker(60, ns.BanResolveNow)
end)

-- Tab "Bans" im Fenster: Meldeformular, offene Abstimmungen mit Ja/Nein-Knöpfen, Ausgeschlossene mit "Lift vote".
local function Remaining(case)
    local s = case.startTime + Ban.DURATION - time()
    if s <= 0 then return "ended" end
    return ("%dh %02dm"):format(math.floor(s / 3600), math.floor(s % 3600 / 60))
end

local widgets

local function EnsureWidgets(f)
    if widgets then return widgets end
    local top, rowH = f.TOP, f.ROW_H
    local w = { yes = {}, no = {}, lift = {}, actions = {} }
    local function Y(r) return top - r * rowH end

    -- Meldeformular (Zeile 1)
    w.pLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    w.pLabel:SetPoint("TOPLEFT", 16, Y(1) - 4)
    w.pLabel:SetText("Player:")
    w.pBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    w.pBox:SetSize(140, 20)
    w.pBox:SetPoint("LEFT", w.pLabel, "RIGHT", 10, 0)
    w.pBox:SetAutoFocus(false)
    w.pBox:SetMaxLetters(30)
    w.rLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    w.rLabel:SetPoint("LEFT", w.pBox, "RIGHT", 14, 0)
    w.rLabel:SetText("Reason:")
    w.rBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    w.rBox:SetSize(180, 20)
    w.rBox:SetPoint("LEFT", w.rLabel, "RIGHT", 10, 0)
    w.rBox:SetAutoFocus(false)
    w.rBox:SetMaxLetters(Ban.MAX_REASON)
    w.report = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    w.report:SetSize(64, 22)
    w.report:SetPoint("LEFT", w.rBox, "RIGHT", 8, 0)
    w.report:SetText("Report")
    local function DoReport()
        local name = (w.pBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local reason = (w.rBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then ns.Print("Please type the player name."); return end
        if #reason < 3 then ns.Print("Please give a short reason."); return end
        ns.commands.report(name .. " " .. reason)
        w.rBox:SetText("")
        w.rBox:ClearFocus()
        w.pBox:ClearFocus()
    end
    w.report:SetScript("OnClick", DoReport)
    w.rBox:SetScript("OnEnterPressed", DoReport)
    w.pBox:SetScript("OnEnterPressed", function() w.rBox:SetFocus() end)
    w.pBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    w.rBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Hinweistext unten (Zeilen 16-18): warum es diese Funktion gibt
    w.info = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    w.info:SetPoint("TOPLEFT", 16, Y(16))
    w.info:SetWidth(f:GetWidth() - 32)
    w.info:SetJustifyH("LEFT")
    w.info:SetJustifyV("TOP")
    w.info:SetText(table.concat({
        "|cffffd100Honor|r",
        "|cffc0c0c0Fightclub runs on honor. You fight clean, or you do not fight at all.",
        ("Hack, cheat or fake a fight and you are no fighter: the club votes, and the door closes behind you. %d votes, 2/3 yes, %d days outside.|r"):format(
            Ban.MIN_VOTES, Ban.BAN_TIME / 86400),
    }, "\n"))

    -- Knöpfe pro Zeile
    for r = 1, #f.rows do
        local yes = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        yes:SetSize(44, 20); yes:SetPoint("TOPLEFT", 420, Y(r) + 2); yes:SetText("Yes")
        yes:SetScript("OnClick", function()
            local a = w.actions[r]
            if a then ns.BanCastVote(true, a.target) end
        end)
        local no = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        no:SetSize(44, 20); no:SetPoint("TOPLEFT", 468, Y(r) + 2); no:SetText("No")
        no:SetScript("OnClick", function()
            local a = w.actions[r]
            if a then ns.BanCastVote(false, a.target) end
        end)
        local lift = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        lift:SetSize(92, 20); lift:SetPoint("TOPLEFT", 420, Y(r) + 2); lift:SetText("Lift vote")
        lift:SetScript("OnClick", function()
            local a = w.actions[r]
            if a then ns.commands.lift(a.target) end
        end)
        yes:Hide(); no:Hide(); lift:Hide()
        w.yes[r], w.no[r], w.lift[r] = yes, no, lift
    end
    widgets = w
    return w
end

-- Bans-Tab öffnen, Namen eintragen und in das Feld "Reason" springen.
function ns.BanPrefill(name)
    if ns.ShowTab then ns.ShowTab("bans") end
    if widgets then
        widgets.pBox:SetText(name or "")
        widgets.rBox:SetFocus()
    end
end

function ns.BanHideWidgets()
    if not widgets then return end
    widgets.info:Hide()
    widgets.pLabel:Hide(); widgets.pBox:Hide(); widgets.rLabel:Hide(); widgets.rBox:Hide(); widgets.report:Hide()
    for r = 1, #widgets.yes do
        widgets.yes[r]:Hide(); widgets.no[r]:Hide(); widgets.lift[r]:Hide()
    end
end

function ns.BanRenderTab(f, header)
    local w = EnsureWidgets(f)
    ns.BanHideWidgets()
    header:SetText("")
    header:Hide()
    w.info:Show()
    w.pLabel:Show(); w.pBox:Show(); w.rLabel:Show(); w.rBox:Show(); w.report:Show()
    w.actions = {}

    local s, now, me = State(), time(), MyName()
    local entries = ns.BuildEntries()
    local canVote = Ban.IsVoter(s, entries, me, now)
    local lines = { [1] = "" } -- Zeile 1 gehört dem Formular
    local function Add(text, action)
        lines[#lines + 1] = text
        if action then w.actions[#lines] = action end
        return #lines
    end

    local mine = s.banned[me]
    if mine and mine.untilT > now then
        Add("|cffff4040You are excluded until " .. date("%d.%m.%Y", mine.untilT) .. "|r")
    elseif not canVote then
        Add("|cffa0a0a0You can report and vote once you have wins against " .. Ban.MIN_DISTINCT .. " different opponents.|r")
    else
        Add("|cff1eff00You may report and vote.|r")
    end

    local cases = {}
    for _, c in pairs(s.cases) do cases[#cases + 1] = c end
    table.sort(cases, function(a, b) return a.startTime < b.startTime end)
    Add("|cffffd100Open votes|r")
    if #cases == 0 then Add("   none") end
    for i, c in ipairs(cases) do
        if i > 3 then Add(("   +%d more (use /fc ban yes|no <player>)"):format(#cases - 3)); break end
        local y, n = Ban.Tally(c)
        local mv = c.votes[me]
        local marker = mv == true and " |cff1eff00(you: Yes)|r" or (mv == false and " |cffff4040(you: No)|r" or "")
        local r = Add(("%s |cffffd100%s|r by %s  Yes %d / No %d  %s%s"):format(
            c.kind == "ban" and "Exclude" or "Readmit", c.target, c.reporter, y, n, Remaining(c), marker),
            { type = "case", target = c.target })
        if c.reason ~= "" then Add("      Reason: " .. c.reason) end
    end

    local banned = {}
    for name, b in pairs(s.banned) do if b.untilT > now then banned[#banned + 1] = name end end
    table.sort(banned)
    Add("|cffffd100Excluded players|r")
    if #banned == 0 then Add("   none") end
    for i, name in ipairs(banned) do
        if i > 3 then Add(("   +%d more"):format(#banned - 3)); break end
        Add(("   %s  until %s"):format(name, date("%d.%m.%Y", s.banned[name].untilT)),
            (not s.cases[name]) and { type = "banned", target = name } or nil)
    end


    for i, row in ipairs(f.rows) do
        row:SetWidth(396)
        row:SetText(lines[i] or "")
    end
    for i = 1, #f.rows do
        local a = w.actions[i]
        if a and a.type == "case" then
            local case = s.cases[a.target]
            local can = canVote and case and a.target ~= me and now < case.startTime + Ban.DURATION
            w.yes[i]:Show(); w.no[i]:Show()
            w.yes[i]:SetEnabled(can and true or false)
            w.no[i]:SetEnabled(can and true or false)
        elseif a and a.type == "banned" then
            w.lift[i]:Show()
            w.lift[i]:SetEnabled(canVote)
        end
    end
end

ns.commands.report = function(rest) Open("ban", rest or "") end
ns.commands.lift = function(rest) Open("lift", rest or "") end
ns.commands.ban = function(rest)
    local word, name = (rest or ""):match("^(%S+)%s*(.-)$")
    word = word and word:lower()
    if word == "yes" or word == "ja" then ns.BanCastVote(true, name)
    elseif word == "no" or word == "nein" then ns.BanCastVote(false, name)
    else ns.Print("Usage: /fc ban yes|no [player]") end
end
ns.commands.bans = function() if ns.ShowTab then ns.ShowTab("bans") end end
