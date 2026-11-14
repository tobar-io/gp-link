-- @description GP-Link: background auto-sync (on/off). Run again to stop.
-- Watches the linked GP file of the active project. As soon as Guitar Pro saves,
-- the project is synced automatically (not while recording).
local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
local R = dofile(dir .. "gplink_reaper.lua")

local _, _, section, cmd = reaper.get_action_context()
reaper.SetToggleCommandState(section, cmd, 1)
reaper.RefreshToolbar2(section, cmd)

local tick = R.new_watcher()

local function loop()
  tick()
  reaper.defer(loop)
end

reaper.atexit(function()
  reaper.SetToggleCommandState(section, cmd, 0)
  reaper.RefreshToolbar2(section, cmd)
end)

R.msg("[GP-Link] Auto-sync active. Run the script again to stop it.")
loop()
