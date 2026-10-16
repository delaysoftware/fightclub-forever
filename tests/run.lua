-- Aufruf aus dem Repo-Root: lua tests/run.lua
local passed, failed = 0, 0

function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. "\n  " .. tostring(err))
    end
end

function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

function truthy(v, msg)
    if not v then error((msg or "truthy") .. ": got " .. tostring(v), 2) end
end

for _, file in ipairs({ "tests/home_test.lua", "tests/codec_test.lua", "tests/boost_test.lua", "tests/ban_test.lua", "tests/net_test.lua", "tests/sim_duel_test.lua" }) do
    local f = io.open(file, "r")
    if f then f:close(); dofile(file) end
end

print(passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
