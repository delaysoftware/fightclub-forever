local _, ns = ...

-- Wire-Format (Felder durch "|", Protokollversion 1):
--   PROPOSE|1|proposer|mapID|x|y|name|startTime
--   VOTE|1|id|Y|N|ts
--   CUR|1|epoch|mapID|x|y|name|since
--   VOTES|1|id|name:Y:ts,name:N:ts,...  (in Teile ≤ 255 Zeichen zerlegt)
-- ts = Zeitstempel der Stimme; die jüngste Stimme pro Spieler gewinnt.
local Codec = {}
ns.HomeCodec = Codec

Codec.PROTO = 1
Codec.MAX_MSG = 255
local MAX_NAME = 16
local MAX_PLAYER = 40 -- Vor- und Nachname
local MAX_ID = 64

local function Clean(s, max)
    s = tostring(s):gsub("[|%c,:]", "")
    return ns.Home.TruncateUtf8(s, max)
end

local function Coord(v) return ("%.4f"):format(v) end

local function Split(text)
    local fields = {}
    for field in (text .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
    return fields
end

local function IsUnit(v) return v ~= nil and v == v and v >= 0 and v <= 1 end
local function IsInt(v) return v ~= nil and v == v and v >= 1 and v < 2 ^ 31 and math.floor(v) == v end
local function IsPlayer(s) return #s >= 1 and #s <= MAX_PLAYER and not s:find("[|%c,:]") end

-- Hilfsfunktionen für BanCodec.lua
Codec.Clean, Codec.Split, Codec.IsInt, Codec.IsPlayer = Clean, Split, IsInt, IsPlayer
Codec.MAX_PLAYER, Codec.MAX_ID = MAX_PLAYER, MAX_ID

function Codec.EncodeProposal(p)
    return table.concat({ "PROPOSE", Codec.PROTO, Clean(p.proposer, MAX_PLAYER), p.mapID,
        Coord(p.x), Coord(p.y), Clean(p.name, MAX_NAME), p.startTime }, "|")
end

function Codec.EncodeVote(id, yes, ts)
    return table.concat({ "VOTE", Codec.PROTO, Clean(id, MAX_ID), yes and "Y" or "N", math.floor(ts) }, "|")
end

function Codec.EncodeCurrent(c)
    return table.concat({ "CUR", Codec.PROTO, c.epoch, c.mapID,
        Coord(c.x), Coord(c.y), Clean(c.name, MAX_NAME), c.since }, "|")
end

-- kind: Nachrichtenart (Standard "VOTES"; BanCodec nutzt "BVOTES").
function Codec.EncodeVotes(id, votes, times, kind)
    local names = {}
    for name in pairs(votes) do names[#names + 1] = name end
    table.sort(names)
    local header = table.concat({ kind or "VOTES", Codec.PROTO, Clean(id, MAX_ID) }, "|") .. "|"
    local parts, current = {}, nil
    for _, name in ipairs(names) do
        local entry = Clean(name, MAX_PLAYER) .. ":" .. (votes[name] and "Y" or "N")
            .. ":" .. math.floor(times and times[name] or 1)
        if current and #current + 1 + #entry <= Codec.MAX_MSG then
            current = current .. "," .. entry
        else
            if current then parts[#parts + 1] = current end
            current = header .. entry
        end
    end
    if current then parts[#parts + 1] = current end
    return parts
end

function Codec.ParseVotes(field)
    local votes, times = {}, {}
    for entry in (field .. ","):gmatch("([^,]*),") do
        local name, v, t = entry:match("^([^:]+):([YN]):(%d+)$")
        local ts = tonumber(t)
        if not name or not IsPlayer(name) or not IsInt(ts) then return nil end
        votes[name] = (v == "Y")
        times[name] = ts
    end
    return votes, times
end

function Codec.Decode(text)
    if type(text) ~= "string" or #text > 1000 then return nil end
    local f = Split(text)
    if tonumber(f[2]) ~= Codec.PROTO then return nil end
    local kind = f[1]

    if kind == "PROPOSE" then
        if #f ~= 8 then return nil end
        local mapID, x, y, start = tonumber(f[4]), tonumber(f[5]), tonumber(f[6]), tonumber(f[8])
        if not (IsPlayer(f[3]) and IsInt(mapID) and IsUnit(x) and IsUnit(y) and IsInt(start)) then return nil end
        return { kind = kind, p = { proposer = f[3], mapID = mapID, x = x, y = y,
            name = ns.Home.TruncateUtf8(f[7], MAX_NAME), startTime = start } }

    elseif kind == "VOTE" then
        if #f ~= 5 or #f[3] < 1 or #f[3] > MAX_ID or (f[4] ~= "Y" and f[4] ~= "N") then return nil end
        local ts = tonumber(f[5])
        if not IsInt(ts) then return nil end
        return { kind = kind, id = f[3], yes = (f[4] == "Y"), ts = ts }

    elseif kind == "CUR" then
        if #f ~= 8 then return nil end
        local epoch, mapID, x, y, since = tonumber(f[3]), tonumber(f[4]), tonumber(f[5]), tonumber(f[6]), tonumber(f[8])
        if not (IsInt(epoch) and IsInt(mapID) and IsUnit(x) and IsUnit(y) and IsInt(since)) then return nil end
        return { kind = kind, current = { epoch = epoch, mapID = mapID, x = x, y = y,
            name = ns.Home.TruncateUtf8(f[7], MAX_NAME), since = since } }

    elseif kind == "VOTES" then
        if #f ~= 4 or #f[3] < 1 or #f[3] > MAX_ID then return nil end
        local votes, times = Codec.ParseVotes(f[4])
        if not votes then return nil end
        return { kind = kind, id = f[3], votes = votes, times = times }
    end
    return nil
end
