-- @description GP-Link internal: one-shot auto-sync (called by the GP-Link extension).
-- Only syncs if the GP file content changed since the last sync.
local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
local R = dofile(dir .. "gplink_reaper.lua")

if R.busy() then return end -- a sync is waiting for an answer (e.g. "items were moved")

local proj = reaper.EnumProjects(-1)
local link = R.load_link(proj)
if not link then return end

-- project saved for the first time after the import: remember the .gp path relative to it
-- (Google Drive / Dropbox paths differ between band members)
local _, rel = reaper.GetProjExtState(proj, "GPLINK", "file_rel")
local pdir = R.project_dir(proj)
if rel == "" and pdir and pdir ~= "" then
  local r = R.relpath(pdir, link.file)
  if r and r ~= "" then reaper.SetProjExtState(proj, "GPLINK", "file_rel", r) end
end
local content = R.read_file(link.file)
if not content or R.core.hash(content) == link.sig then return end

local ok, res = pcall(R.sync, proj, { quiet = true })
if not ok then
  R.msg("[GP-Link] Auto-sync failed: " .. tostring(res))
else
  reaper.SetExtState("GPLINK_EXT", "last_report", res, false)
end
