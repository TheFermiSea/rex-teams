-- The far end of send.lua host=HOST. send.lua runs this with `rex -S HOST`,
-- so every call here goes to the receiver's Rex server. Not for agents to run.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
lib.far(function() print(lib.deliver(rex.args)) end)
