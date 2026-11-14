-- @description GP-Link: link a Guitar Pro file, map tracks and sync
-- Also called by the GP-Link extension when a .gp/.gpx/.gp5 file is dropped onto the arrange view.
local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
local R = dofile(dir .. "gplink_reaper.lua")

-- drag & drop from the extension: file + drop position
local drop_file = reaper.GetExtState("GPLINK_DROP", "file")
local drop_pos = tonumber(reaper.GetExtState("GPLINK_DROP", "pos"))
reaper.DeleteExtState("GPLINK_DROP", "file", false)
reaper.DeleteExtState("GPLINK_DROP", "pos", false)

local file, opts = nil, {}
if drop_file ~= "" then
  file = drop_file
  opts.anchor_time = drop_pos
end

local ok, err = pcall(R.import, 0, file, opts)
if not ok then reaper.MB(tostring(err), "GP-Link error", 0) end
