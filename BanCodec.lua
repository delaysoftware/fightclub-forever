local _, ns = ...

-- Wire-Format für Ausschluss-Abstimmungen (Felder durch "|", Protokollversion 1):
--   BCASE|1|B oder L|reporter|target|reason|startTime   (B = Ausschluss, L = Aufhebung)
--   BVOTE|1|id|Y oder N|ts
--   BVOTES|1|id|name:Y:ts,...                            (in Teile ≤ 255 Zeichen zerlegt)
--   BBAN|1|target|since|untilT                           (Meldung eines verhängten Ausschlusses)
local H = ns.HomeCodec
local Codec = {}
ns.BanCodec = Codec

local MAX_REASON = 40

function Codec.EncodeCase(c)
    return table.concat({ "BCASE", H.PROTO, c.kind == "lift" and "L" or "B", H.Clean(c.reporter, H.MAX_PLAYER),
        H.Clean(c.target, H.MAX_PLAYER), H.Clean(c.reason or "", MAX_REASON), math.floor(c.startTime) }, "|")
end

function Codec.EncodeVote(id, yes, ts)
    return table.concat({ "BVOTE", H.PROTO, H.Clean(id, H.MAX_ID), yes and "Y" or "N", math.floor(ts) }, "|")
end

function Codec.EncodeVotes(id, votes, times)
    return H.EncodeVotes(id, votes, times, "BVOTES")
end

function Codec.EncodeBan(target, since, untilT)
    return table.concat({ "BBAN", H.PROTO, H.Clean(target, H.MAX_PLAYER), math.floor(since), math.floor(untilT) }, "|")
end

function Codec.Decode(text)
    if type(text) ~= "string" or #text > 1000 then return nil end
    local f = H.Split(text)
    if tonumber(f[2]) ~= H.PROTO then return nil end
    local kind = f[1]

    if kind == "BCASE" then
        if #f ~= 7 or (f[3] ~= "B" and f[3] ~= "L") then return nil end
        local start = tonumber(f[7])
        if not (H.IsPlayer(f[4]) and H.IsPlayer(f[5]) and H.IsInt(start)) then return nil end
        return { kind = kind, c = { kind = f[3] == "L" and "lift" or "ban", reporter = f[4], target = f[5],
            reason = ns.Home.TruncateUtf8(f[6], MAX_REASON), startTime = start } }

    elseif kind == "BVOTE" then
        if #f ~= 5 or #f[3] < 1 or #f[3] > H.MAX_ID or (f[4] ~= "Y" and f[4] ~= "N") then return nil end
        local ts = tonumber(f[5])
        if not H.IsInt(ts) then return nil end
        return { kind = kind, id = f[3], yes = (f[4] == "Y"), ts = ts }

    elseif kind == "BVOTES" then
        if #f ~= 4 or #f[3] < 1 or #f[3] > H.MAX_ID then return nil end
        local votes, times = H.ParseVotes(f[4])
        if not votes then return nil end
        return { kind = kind, id = f[3], votes = votes, times = times }

    elseif kind == "BBAN" then
        if #f ~= 5 or not H.IsPlayer(f[3]) then return nil end
        local since, untilT = tonumber(f[4]), tonumber(f[5])
        if not (H.IsInt(since) and H.IsInt(untilT)) then return nil end
        return { kind = kind, target = f[3], since = since, untilT = untilT }
    end
    return nil
end
