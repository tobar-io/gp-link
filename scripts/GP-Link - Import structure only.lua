-- @description GP-Link: import project structure from Guitar Pro (tempo, time signatures, sections, markers, chords - no MIDI)
-- Opens the import dialog with MIDI notes/lyrics unchecked. Everything can still be changed in the dialog.
local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
local R = dofile(dir .. "gplink_reaper.lua")

local function run()
  local proj = 0
  local link = R.load_link(proj)
  local file = link and link.file or nil
  if not file then
    file = R.choose_gp_file()
    if not file then return end
  end
  R.import(proj, file, { preset = "structure" })
end

local ok, err = pcall(run)
if not ok then reaper.MB(tostring(err), "GP-Link error", 0) end
