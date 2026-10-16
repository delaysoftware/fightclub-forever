local _, ns = ...

-- Rechtsklick-Menü auf Spieler: "Fightclub duel (ranked)" und "Fightclub duel (unranked)".
-- Fallback ohne Menü-API: /fc duel ranked|unranked (Ziel anvisieren).
-- Hinweis: Die Menü-API (Menu.ModifyMenu) und StartDuel sind im Forever-Client nicht verifiziert.

-- mode: "R" gewertet, "U" ungewertet (Brawl). unit: Unit-Token oder nil; name: Anzeigename.
function ns.StartFightclubDuel(unit, name, mode)
    local shown = unit and UnitName(unit) or name
    if not shown then ns.Print("No player selected."); return end
    local key = (unit and ns.ResolveMember(UnitName(unit))) or ns.ResolveMember(shown)
    if not key then
        -- Der Menüeintrag enthält evtl. nur den Vornamen; über alle bekannten Schreibweisen suchen.
        for _, n in ipairs(unit and ns.UnitNames(unit) or {}) do
            key = key or ns.ResolveMember(n)
        end
    end
    if not key or ns.IsBanned(key) then
        ns.Print(shown, "is not a Fightclub member – use the normal duel option.")
        return
    end
    ns.AnnounceDuelMode(key, mode)
    local ok, err = pcall(StartDuel, unit or shown)
    if not ok then ns.Print("Could not start the duel:", tostring(err)) end
end

ns.commands.duel = function(arg)
    arg = (arg or ""):lower()
    local mode = (arg == "unranked" or arg == "brawl") and "U" or (arg == "ranked" and "R" or nil)
    if not mode then ns.Print("Usage: /fc duel ranked|unranked (with your target selected)"); return end
    if not UnitExists("target") or not UnitIsPlayer("target") then ns.Print("Select a player first."); return end
    ns.StartFightclubDuel("target", nil, mode)
end

local MENUS = {
    "MENU_UNIT_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_FRIEND", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_FOCUS",
}

local function Extend(owner, root, context)
    local unit = context and context.unit
    local name = context and context.name
    if unit and (not UnitIsPlayer(unit) or UnitIsUnit(unit, "player")) then return end
    if not unit and (not name or ns.IsSelf(name)) then return end
    root:CreateDivider()
    root:CreateTitle("Fightclub")
    root:CreateButton("Fightclub duel (ranked)", function() ns.StartFightclubDuel(unit, name, "R") end)
    root:CreateButton("Fightclub duel (unranked)", function() ns.StartFightclubDuel(unit, name, "U") end)
    root:CreateButton("Fightclub: offer Brawl reset", function()
        ns.OfferBrawlReset((unit and ns.KeyForUnit(unit)) or (name and ns.ResolveMember(name)))
    end)
end

ns.RegisterEvent("PLAYER_LOGIN", function()
    if not (Menu and Menu.ModifyMenu) then
        ns.Print("Right-click menu not available in this client – use /fc duel ranked|unranked.")
        return
    end
    local added = 0
    for _, tag in ipairs(MENUS) do
        if pcall(Menu.ModifyMenu, tag, Extend) then added = added + 1 end
    end
    if added == 0 then ns.Print("Could not extend the right-click menu – use /fc duel ranked|unranked.") end
end)
