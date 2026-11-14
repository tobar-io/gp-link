-- @description GP-Link: re-read the linked Guitar Pro file now
local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
local R = dofile(dir .. "gplink_reaper.lua")

local ok, err = pcall(R.sync, 0)
if not ok then reaper.MB(tostring(err), "GP-Link error", 0) end
