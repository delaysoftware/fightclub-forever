-- Lädt die reinen Module mit einem frischen Namespace.
local ns = {}
for _, file in ipairs({ "CharData.lua", "Home.lua", "HomeCodec.lua", "Rating.lua", "Members.lua", "Boost.lua", "DuelParse.lua", "Rules.lua", "Ban.lua", "BanCodec.lua" }) do
    local f = io.open(file, "r")
    if f then
        f:close()
        assert(loadfile(file))("Fightclub", ns)
    end
end
return ns
