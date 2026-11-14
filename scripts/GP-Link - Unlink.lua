-- @description GP-Link: unlink the Guitar Pro file from this project (tracks, items and regions are kept)
local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
local R = dofile(dir .. "gplink_reaper.lua")

local proj = reaper.EnumProjects(-1)
local link = R.load_link(proj)
if not link then
  reaper.MB("This project is not linked to a Guitar Pro file.", "GP-Link", 0)
  return
end
local msg = "Unlink " .. (link.file or "the GP file") .. "?\n\n"
  .. "MIDI items, tracks and regions are kept, but are no longer synced."
if reaper.MB(msg, "GP-Link", 4) == 6 then R.unlink(proj) end
