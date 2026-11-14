-- GP-Link: REAPER side (file extraction, project link state, import dialog, sync).

local R = {}

local SCRIPT_DIR = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
R.dir = SCRIPT_DIR
local core = dofile(SCRIPT_DIR .. "gplink_core.lua")
R.core = core
local formats = dofile(SCRIPT_DIR .. "gplink_formats.lua")
R.formats = formats

-- supported Guitar Pro files: GP5 (.gp5), GP6 (.gpx), GP7/8 (.gp)
R.GP_EXTENSIONS = { gp = true, gpx = true, gp5 = true }
function R.is_gp_file(path)
  local ext = tostring(path or ""):match("%.([%w]+)$")
  return ext ~= nil and R.GP_EXTENSIONS[ext:lower()] == true
end

function R.choose_gp_file()
  local ok, f = reaper.GetUserFileNameForRead("", "Choose a Guitar Pro file (.gp, .gpx, .gp5)", "")
  if not ok or f == "" then return nil end
  return f
end

local EXT = "GPLINK"
local ITEM_TAG = "P_EXT:GPLINK"
local CHORD_KEY = "__chords"

-- import building blocks ("Bausteine"), order = dialog order
R.OPTS = {
  { key = "tempo", label = "Tempo & time signatures", default = true },
  { key = "regions", label = "Sections as regions", default = true },
  { key = "section_markers", label = "Sections as markers", default = false },
  { key = "number_sections", label = "Number repeated sections", default = true },
  { key = "text_markers", label = "Text, jumps, key changes as markers", default = true },
  { key = "chords", label = "Chords (track 'Chords')", default = true },
  { key = "midi", label = "MIDI notes", default = true },
  { key = "lyrics", label = "Lyrics (in the MIDI items)", default = true },
}

function R.default_opts()
  local o = {}
  for _, d in ipairs(R.OPTS) do o[d.key] = d.default end
  return o
end

function R.load_config()
  local ok, cfg = pcall(dofile, SCRIPT_DIR .. "gplink_config.lua")
  if ok and type(cfg) == "table" then return cfg end
  return {}
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function msg(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end
R.msg = msg

function R.read_file(p)
  if not p then return nil end
  local f = io.open(p, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end

local function file_exists(p)
  local f = p and io.open(p, "rb")
  if f then f:close() return true end
  return false
end

local IS_WIN = reaper.GetOS():match("Win") ~= nil
local SEP = IS_WIN and "\\" or "/"

-- Extract Content/score.gpif from a .gp (zip) file using the system tar/unzip.
function R.extract_gpif(gp_path)
  local tmp = reaper.GetResourcePath() .. SEP .. "GP-Link-tmp"
  reaper.RecursiveCreateDirectory(tmp, 0)
  local out = tmp .. SEP .. "Content" .. SEP .. "score.gpif"
  os.remove(out)
  local cmd
  if IS_WIN then
    local tar = os.getenv("SystemRoot") and (os.getenv("SystemRoot") .. "\\System32\\tar.exe") or "tar.exe"
    if not file_exists(tar) then tar = "tar.exe" end
    cmd = string.format('"%s" -xf "%s" -C "%s" Content/score.gpif', tar, gp_path, tmp)
  else
    cmd = string.format('/usr/bin/unzip -o -qq "%s" Content/score.gpif -d "%s"', gp_path, tmp)
  end
  local res = reaper.ExecProcess(cmd, 20000)
  local xml = R.read_file(out)
  if not xml then
    error("Could not read score.gpif from the GP file.\nSupported: Guitar Pro 5-8 (.gp5, .gpx, .gp).\n" ..
      "Command: " .. cmd .. "\nOutput: " .. tostring(res))
  end
  return xml
end

---------------------------------------------------------------------------
-- Paths (relative to the project file, so links survive other machines / cloud drives)
---------------------------------------------------------------------------

local function split_path(p)
  local parts = {}
  for s in p:gmatch("[^\\/]+") do parts[#parts + 1] = s end
  return parts
end

function R.project_dir(proj)
  local fn
  if proj == 0 or proj == nil then
    local _, f = reaper.EnumProjects(-1)
    fn = f
  else
    local i = 0
    while true do
      local p, f = reaper.EnumProjects(i)
      if not p then break end
      if p == proj then fn = f break end
      i = i + 1
    end
  end
  if not fn or fn == "" then return nil end
  return fn:match("^(.*)[\\/]")
end

function R.relpath(dir, file)
  if not dir or not file then return nil end
  local a, b = split_path(dir), split_path(file)
  local function same(x, y) if IS_WIN then return x:lower() == y:lower() end return x == y end
  if #a == 0 or #b == 0 or not same(a[1], b[1]) then return nil end -- other drive
  local i = 1
  while i <= #a and i < #b and same(a[i], b[i]) do i = i + 1 end
  local out = {}
  for _ = i, #a do out[#out + 1] = ".." end
  for j = i, #b do out[#out + 1] = b[j] end
  return table.concat(out, SEP)
end

local function join(dir, rel)
  local parts = split_path(dir)
  local lead = dir:match("^[\\/]") and SEP or ""
  for _, s in ipairs(split_path(rel)) do
    if s == ".." then table.remove(parts) elseif s ~= "." then parts[#parts + 1] = s end
  end
  return lead .. table.concat(parts, SEP)
end

-- first existing of: project-relative path, stored absolute path, file name next to the project
function R.resolve_file(proj, abs, rel)
  local dir = R.project_dir(proj)
  if dir and rel and rel ~= "" then
    local p = join(dir, rel)
    if file_exists(p) then return p end
  end
  if file_exists(abs) then return abs end
  if dir and abs then
    local p = dir .. SEP .. (abs:match("[^\\/]+$") or abs)
    if file_exists(p) then return p end
  end
  return abs
end

---------------------------------------------------------------------------
-- Project link state
---------------------------------------------------------------------------

local function get(proj, key)
  local _, v = reaper.GetProjExtState(proj, EXT, key)
  return v ~= "" and v or nil
end
local function set(proj, key, v) reaper.SetProjExtState(proj, EXT, key, v or "") end

local function parse_list(s)
  local out = {}
  for line in (s or ""):gmatch("[^\n]+") do
    local idx, name = line:match("^(%d+)\t(.*)$")
    if idx then out[#out + 1] = { idx = tonumber(idx), name = name } end
  end
  return out
end
local function format_list(l)
  local rl = {}
  for _, r in ipairs(l or {}) do rl[#rl + 1] = r.idx .. "\t" .. r.name end
  return table.concat(rl, "\n")
end

function R.load_link(proj)
  local stored = get(proj, "file")
  if not stored then return nil end
  local rel = get(proj, "file_rel")
  local link = {
    file = R.resolve_file(proj, stored, rel),
    file_stored = stored,
    anchor = tonumber(get(proj, "anchor")) or 0, -- 0-based REAPER measure
    countin = tonumber(get(proj, "countin")) or 0,
    tempo_fp = get(proj, "tempo_fp"),
    sig = get(proj, "sig"),
    last_sync = get(proj, "last_sync"),
    chords_track = get(proj, "chords_track"),
    map = {},
    regions = parse_list(get(proj, "regions")),
    markers = parse_list(get(proj, "markers")),
    opts = R.default_opts(),
  }
  for line in (get(proj, "map") or ""):gmatch("[^\n]+") do
    local key, guid = line:match("^(.-)\t(.*)$")
    if key then link.map[key] = guid end
  end
  for k, v in (get(proj, "opts") or ""):gmatch("([%w_]+)=(%d)") do link.opts[k] = (v == "1") end
  return link
end

function R.save_link(proj, link)
  set(proj, "file", link.file)
  set(proj, "file_rel", R.relpath(R.project_dir(proj), link.file))
  set(proj, "anchor", tostring(link.anchor or 0))
  set(proj, "countin", tostring(link.countin or 0))
  set(proj, "tempo_fp", link.tempo_fp)
  set(proj, "sig", link.sig)
  set(proj, "last_sync", link.last_sync)
  set(proj, "chords_track", link.chords_track)
  local lines = {}
  for k, g in pairs(link.map) do lines[#lines + 1] = k .. "\t" .. g end
  table.sort(lines)
  set(proj, "map", table.concat(lines, "\n"))
  set(proj, "regions", format_list(link.regions))
  set(proj, "markers", format_list(link.markers))
  local o = {}
  for _, d in ipairs(R.OPTS) do o[#o + 1] = d.key .. "=" .. ((link.opts or {})[d.key] and "1" or "0") end
  set(proj, "opts", table.concat(o, ";"))
  reaper.MarkProjectDirty(proj)
end

-- remove the link (GP items, tracks and regions stay in the project)
function R.unlink(proj)
  reaper.SetProjExtState(proj, EXT, "", "")
  reaper.MarkProjectDirty(proj)
end

-- unique key per GP track: name, plus #n for duplicate names
function R.track_keys(tl)
  local seen, keys = {}, {}
  for i, t in ipairs(tl.tracks) do
    seen[t.name] = (seen[t.name] or 0) + 1
    keys[i] = seen[t.name] > 1 and (t.name .. "#" .. seen[t.name]) or t.name
  end
  return keys
end

---------------------------------------------------------------------------
-- Tracks
---------------------------------------------------------------------------

function R.find_track_by_guid(proj, guid)
  if not guid then return nil end
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetTrackGUID(tr) == guid then return tr, i end
  end
  return nil
end

function R.track_name(tr)
  local _, n = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  return n
end

function R.create_track(proj, name, color, index)
  local idx = index or reaper.CountTracks(proj)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(proj, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  if color then
    reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR",
      reaper.ColorToNative(color[1], color[2], color[3]) | 0x1000000)
  end
  return tr
end

---------------------------------------------------------------------------
-- Tempo map
---------------------------------------------------------------------------

local function write_tempo(proj, anchor, tl)
  local anchor_time = reaper.TimeMap_GetMeasureInfo(proj, anchor)
  for i = reaper.CountTempoTimeSigMarkers(proj) - 1, 0, -1 do
    local _, tpos = reaper.GetTempoTimeSigMarker(proj, i)
    if tpos >= anchor_time - 1e-6 then reaper.DeleteTempoTimeSigMarker(proj, i) end
  end
  for _, t in ipairs(tl.tempo) do
    local beatpos = 0
    if t.beat_frac and t.beat_frac > 0 then
      local b = tl.bars[t.bar + 1]
      beatpos = t.beat_frac * (b and b.num or 4)
    end
    reaper.SetTempoTimeSigMarker(proj, -1, -1, anchor + t.bar, beatpos, t.bpm, t.num or 0, t.den or 0, t.linear)
  end
  reaper.UpdateTimeline()
end

---------------------------------------------------------------------------
-- Regions / markers (only the ones GP-Link created are touched)
---------------------------------------------------------------------------

local function delete_marks(proj, list, isrgn)
  for _, r in ipairs(list or {}) do
    local i = 0
    while true do
      local ret, rg, _, _, name, idx = reaper.EnumProjectMarkers3(proj, i)
      if ret == 0 then break end
      if rg == isrgn and idx == r.idx and name == r.name then
        reaper.DeleteProjectMarker(proj, idx, isrgn)
        break
      end
      i = i + 1
    end
  end
end

local SECTION_COLORS = {
  { 92, 140, 200 }, { 200, 120, 80 }, { 110, 170, 100 }, { 170, 110, 180 },
  { 200, 180, 80 }, { 80, 170, 170 }, { 190, 90, 110 }, { 130, 130, 130 },
}

local function section_colors(tl)
  local color_of, ci, out = {}, 0, {}
  for i, s in ipairs(tl.sections) do
    local key = (s.letter and s.letter ~= "") and s.letter or s.base or s.name
    if not color_of[key] then
      ci = ci % #SECTION_COLORS + 1
      color_of[key] = SECTION_COLORS[ci]
    end
    local c = color_of[key]
    out[i] = reaper.ColorToNative(c[1], c[2], c[3]) | 0x1000000
  end
  return out
end

local function create_regions(proj, anchor_qn, tl)
  local out, colors = {}, section_colors(tl)
  for i, s in ipairs(tl.sections) do
    local t0 = reaper.TimeMap2_QNToTime(proj, anchor_qn + s.qn)
    local t1 = reaper.TimeMap2_QNToTime(proj, anchor_qn + s.qn_end)
    local idx = reaper.AddProjectMarker2(proj, true, t0, t1, s.name, -1, colors[i])
    out[#out + 1] = { idx = idx, name = s.name }
  end
  return out
end

local TEXT_COLOR = reaper.ColorToNative(230, 200, 90) | 0x1000000

local function create_markers(proj, anchor_qn, tl, opts)
  local out = {}
  if opts.section_markers then
    local colors = section_colors(tl)
    for i, s in ipairs(tl.sections) do
      local t = reaper.TimeMap2_QNToTime(proj, anchor_qn + s.qn)
      local idx = reaper.AddProjectMarker2(proj, false, t, 0, s.name, -1, colors[i])
      out[#out + 1] = { idx = idx, name = s.name }
    end
  end
  if opts.text_markers then
    for _, x in ipairs(tl.texts or {}) do
      local t = reaper.TimeMap2_QNToTime(proj, anchor_qn + x.qn)
      local idx = reaper.AddProjectMarker2(proj, false, t, 0, x.text, -1, TEXT_COLOR)
      out[#out + 1] = { idx = idx, name = x.text }
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

local function is_locked(it)
  return (math.floor(reaper.GetMediaItemInfo_Value(it, "C_LOCK") or 0) & 1) == 1
end

-- all GP-Link items in the project: list of { item=, track=, key= }
local function all_tagged_items(proj)
  local out = {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      local _, tag = reaper.GetSetMediaItemInfo_String(it, ITEM_TAG, "", false)
      if tag ~= "" then out[#out + 1] = { item = it, track = tr, key = tag } end
    end
  end
  return out
end

-- GP items the user dragged to another REAPER track (e.g. onto a VSTi track).
-- Returns { [key] = track } plus the keys in GP order.
local function moved_items(proj, map, keys)
  local moves, order = {}, {}
  local wanted = {}
  for _, k in ipairs(keys) do
    local g = map[k]
    if g and g ~= "skip" then wanted[k] = g end
  end
  for _, e in ipairs(all_tagged_items(proj)) do
    local g = wanted[e.key]
    if g and not moves[e.key] and reaper.GetTrackGUID(e.track) ~= g then moves[e.key] = e.track end
  end
  for _, k in ipairs(keys) do if moves[k] then order[#order + 1] = k end end
  return moves, order
end
R.moved_items = moved_items

local function write_item(proj, tr, anchor_qn, ttrack, key, length_qn, with_lyrics)
  local item = reaper.CreateNewMIDIItemInProj(tr, anchor_qn, anchor_qn + length_qn, true)
  if not item then return 0 end
  reaper.GetSetMediaItemInfo_String(item, ITEM_TAG, key, true)
  local take = reaper.GetActiveTake(item)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "GP: " .. ttrack.name, true)
  local n = 0
  for _, ev in ipairs(ttrack.notes) do
    local s = reaper.MIDI_GetPPQPosFromProjQN(take, anchor_qn + ev.s)
    local e = reaper.MIDI_GetPPQPosFromProjQN(take, anchor_qn + ev.e)
    if e - s < 1 then e = s + 1 end
    reaper.MIDI_InsertNote(take, false, false, s, e, ev.c, ev.p, ev.v, true)
    n = n + 1
  end
  if with_lyrics then
    for _, l in ipairs(ttrack.lyrics or {}) do
      local p = reaper.MIDI_GetPPQPosFromProjQN(take, anchor_qn + l.qn)
      reaper.MIDI_InsertTextSysexEvt(take, false, false, p, 5, l.text) -- 5 = lyric
    end
  end
  reaper.MIDI_Sort(take)
  return n
end

local function write_chords(proj, link, anchor_qn, tl)
  local tr = R.find_track_by_guid(proj, link.chords_track)
  if not tr then
    tr = R.create_track(proj, "Chords", { 230, 200, 90 }, 0)
    link.chords_track = reaper.GetTrackGUID(tr)
  end
  for i, c in ipairs(tl.chords) do
    local nxt = tl.chords[i + 1]
    local q1 = nxt and nxt.qn or tl.length
    local t0 = reaper.TimeMap2_QNToTime(proj, anchor_qn + c.qn)
    local t1 = reaper.TimeMap2_QNToTime(proj, anchor_qn + q1)
    local it = reaper.AddMediaItemToTrack(tr)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", t0)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", math.max(0.01, t1 - t0))
    reaper.GetSetMediaItemInfo_String(it, "P_NOTES", c.name, true)
    reaper.GetSetMediaItemInfo_String(it, ITEM_TAG, CHORD_KEY, true)
  end
  return #tl.chords
end

---------------------------------------------------------------------------
-- Load + build
---------------------------------------------------------------------------

function R.load_song(file, cfg)
  local raw = R.read_file(file)
  if not raw then error("GP file not found: " .. tostring(file)) end
  local score
  if formats.is_gpx(raw) then                 -- Guitar Pro 6
    score = core.parse_gpif(formats.gpx_gpif(raw))
  elseif formats.is_gp_binary(raw) then       -- Guitar Pro 5 (older ones get a clear message)
    score = formats.parse_gp5(raw)
  else                                        -- Guitar Pro 7/8 (zip)
    score = core.parse_gpif(R.extract_gpif(file))
  end
  local tl = core.build(score, cfg)
  return score, tl
end

local function build_cfg(link)
  local cfg = R.load_config()
  cfg.number_sections = link.opts.number_sections
  cfg.countin = link.countin or 0
  return cfg
end

---------------------------------------------------------------------------
-- Import dialog
--   native (GP-Link extension, action _GPLINK_IMPORT_DIALOG) or text fallback
---------------------------------------------------------------------------

local function clean(s) return (tostring(s or ""):gsub("[\t\r\n]", " ")) end

local function anchor_default(proj, link, anchor_time)
  if anchor_time or not (link and link.anchor) then
    local t = anchor_time or reaper.GetCursorPositionEx(proj)
    local _, measures = reaper.TimeMap2_timeToBeats(proj, t)
    return measures
  end
  return link.anchor
end

-- defaults per GP track: checked, target ("new" / guid)
local function track_defaults(proj, tl, link)
  local keys = R.track_keys(tl)
  local existing = link and link.map or {}
  local moved = moved_items(proj, existing, keys)
  local out = {}
  for i, t in ipairs(tl.tracks) do
    local key = keys[i]
    local g = existing[key]
    local d = { key = key, checked = true, target = "new" }
    if moved[key] then
      d.target = reaper.GetTrackGUID(moved[key])
    elseif g == "skip" then
      d.checked = false
    elseif g and g ~= "new" and R.find_track_by_guid(proj, g) then
      d.target = g
    elseif not g then
      for j = 0, reaper.CountTracks(proj) - 1 do
        local tr = reaper.GetTrack(proj, j)
        if R.track_name(tr) == t.name then d.target = reaper.GetTrackGUID(tr) break end
      end
    end
    out[i] = d
  end
  return out
end

local function native_dialog(proj, tl, file, link, anchor, opts, defaults)
  local cmd = reaper.NamedCommandLookup and reaper.NamedCommandLookup("_GPLINK_IMPORT_DIALOG") or 0
  if cmd == 0 then return nil, "unavailable" end
  local L = {}
  L[#L + 1] = "title\tGP-Link - " .. clean(file:match("[^\\/]+$") or file)
  L[#L + 1] = "anchor\t" .. (anchor + 1)
  L[#L + 1] = "countin\t" .. (link and link.countin or 0)
  for _, d in ipairs(R.OPTS) do
    L[#L + 1] = "opt\t" .. d.key .. "\t" .. clean(d.label) .. "\t" .. (opts[d.key] and 1 or 0)
  end
  local guid_index = {}
  for j = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, j)
    L[#L + 1] = "target\t" .. (j + 1) .. "\t" .. clean((j + 1) .. ": " .. R.track_name(tr))
    guid_index[reaper.GetTrackGUID(tr)] = j + 1
  end
  for i, t in ipairs(tl.tracks) do
    local d = defaults[i]
    local info = string.format("%s, %d notes", t.is_drums and "Drums" or (t.instrument ~= "" and t.instrument or "?"), #t.notes)
    L[#L + 1] = string.format("track\t%s\t%s\t%s\t%d\t%d", clean(d.key), clean(t.name), clean(info),
      d.checked and 1 or 0, guid_index[d.target] or 0)
  end
  reaper.SetExtState("GPLINK_DLG", "result", "", false)
  reaper.SetExtState("GPLINK_DLG", "spec", table.concat(L, "\n"), false)
  reaper.Main_OnCommand(cmd, 0)
  local res = reaper.GetExtState("GPLINK_DLG", "result")
  if res == "" or not res:match("^ok\t1") then return nil, "cancel" end
  local out = { opts = {}, map = {}, anchor = anchor, countin = 0 }
  for line in res:gmatch("[^\n]+") do
    local f = {}
    for x in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
    if f[1] == "anchor" then out.anchor = math.max(0, (tonumber(f[2]) or 1) - 1)
    elseif f[1] == "countin" then out.countin = math.max(0, math.floor(tonumber(f[2]) or 0))
    elseif f[1] == "opt" then out.opts[f[2]] = f[3] == "1"
    elseif f[1] == "track" then
      local key, checked, tgt = f[2], f[3] == "1", tonumber(f[4]) or 0
      if not checked then out.map[key] = "skip"
      elseif tgt > 0 and reaper.GetTrack(proj, tgt - 1) then out.map[key] = reaper.GetTrackGUID(reaper.GetTrack(proj, tgt - 1))
      else out.map[key] = "new" end
    end
  end
  return out
end

local function sanitize(s) return (s:gsub("[,\n\r]", ";")) end

-- text fallback (no extension): GetUserInputs, paged
local function text_dialog(proj, tl, link, anchor, opts, defaults)
  local test = reaper.GetExtState("GPLINK_TEST", "autoaccept") == "1"
  local guid_index = {}
  for j = 0, reaper.CountTracks(proj) - 1 do guid_index[reaper.GetTrackGUID(reaper.GetTrack(proj, j))] = j + 1 end
  local out = { opts = opts, map = {}, anchor = anchor, countin = link and link.countin or 0 }
  local PAGE = 10
  local pages = math.max(1, math.ceil(#tl.tracks / PAGE))
  for p = 1, pages do
    local caps, vals, idxs = {}, {}, {}
    if p == 1 then
      caps[#caps + 1] = "Start bar in REAPER"; vals[#vals + 1] = tostring(anchor + 1)
      caps[#caps + 1] = "Count-in (bars)"; vals[#vals + 1] = tostring(out.countin)
    end
    for i = (p - 1) * PAGE + 1, math.min(#tl.tracks, p * PAGE) do
      local d = defaults[i]
      caps[#caps + 1] = sanitize(tl.tracks[i].name)
      vals[#vals + 1] = (not d.checked) and "-" or (guid_index[d.target] and tostring(guid_index[d.target]) or "+")
      idxs[#idxs + 1] = i
    end
    caps[#caps + 1] = "extrawidth=120"
    local title = string.format("GP-Link tracks (%d/%d)  + = new, - = skip, number = REAPER track", p, pages)
    local ok, ret
    if test then ok, ret = true, table.concat(vals, ",")
    else ok, ret = reaper.GetUserInputs(title, #caps - 1, table.concat(caps, ","), table.concat(vals, ",")) end
    if not ok then return nil end
    local fields = {}
    for f in (ret .. ","):gmatch("([^,]*),") do fields[#fields + 1] = f end
    local off = 0
    if p == 1 then
      out.anchor = math.max(0, (tonumber(fields[1]) or 1) - 1)
      out.countin = math.max(0, math.floor(tonumber(fields[2]) or 0))
      off = 2
    end
    for k, i in ipairs(idxs) do
      local v = (fields[k + off] or "+"):gsub("%s", "")
      local key = defaults[i].key
      if v == "-" or v == "0" then out.map[key] = "skip"
      elseif tonumber(v) and reaper.GetTrack(proj, tonumber(v) - 1) then
        out.map[key] = reaper.GetTrackGUID(reaper.GetTrack(proj, tonumber(v) - 1))
      else out.map[key] = "new" end
    end
  end
  return out
end

-- returns { map=, anchor=, countin=, opts= } or nil if cancelled
function R.import_dialog(proj, tl, file, link, anchor_time, preset)
  local opts = {}
  for k, v in pairs(link and link.opts or R.default_opts()) do opts[k] = v end
  if preset == "structure" then opts.midi = false; opts.lyrics = false end
  local anchor = anchor_default(proj, link, anchor_time)
  local defaults = track_defaults(proj, tl, link)
  if reaper.GetExtState("GPLINK_TEST", "autoaccept") ~= "1" then
    local res, why = native_dialog(proj, tl, file, link, anchor, opts, defaults)
    if res then return res end
    if why == "cancel" then return nil end
  end
  return text_dialog(proj, tl, link, anchor, opts, defaults)
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

-- GP items dragged onto other tracks: ask whether those tracks become the new sync targets.
-- Yes -> remap, No -> items go back to the linked tracks.
local function ask_moved(proj, link, keys, rep)
  local moves, order = moved_items(proj, link.map, keys)
  if #order == 0 then return end
  local lines = {}
  for _, k in ipairs(order) do
    lines[#lines + 1] = "   " .. k .. "  ->  " .. R.track_name(moves[k])
  end
  local m = "GP items were moved to another track:\n\n" .. table.concat(lines, "\n") ..
    "\n\nSync these Guitar Pro tracks into the new tracks from now on?\n\n" ..
    "Yes = keep syncing there\nNo = move them back to the linked tracks"
  if reaper.MB(m, "GP-Link", 4) ~= 6 then return end
  for _, k in ipairs(order) do
    link.map[k] = reaper.GetTrackGUID(moves[k])
    rep("'" .. k .. "' now syncs into track '" .. R.track_name(moves[k]) .. "'.")
  end
end

local sync_impl

-- Returns report string. `opts.quiet` suppresses console output,
-- `opts.mapped` = track mapping was just chosen in the import dialog (no move question).
function R.sync(proj, opts)
  reaper.SetExtState("GPLINK_EXT", "busy", "1", false)
  local ok, res = pcall(sync_impl, proj, opts)
  reaper.SetExtState("GPLINK_EXT", "busy", "", false)
  if not ok then error(res, 0) end
  return res
end

function R.busy() return reaper.GetExtState("GPLINK_EXT", "busy") == "1" end

sync_impl = function(proj, opts)
  opts = opts or {}
  proj = proj or 0
  local link = R.load_link(proj)
  if not link then error("This project is not linked to a GP file. Import a .gp first.") end
  local raw = R.read_file(link.file)
  if not raw then error("GP file not found: " .. link.file) end
  local o = link.opts
  local _, tl = R.load_song(link.file, build_cfg(link))
  local keys = R.track_keys(tl)

  local report = {}
  local function rep(s) report[#report + 1] = s end
  if o.midi and not opts.mapped then ask_moved(proj, link, keys, rep) end

  reaper.Undo_BeginBlock2(proj)
  reaper.PreventUIRefresh(1)

  -- tempo / time signature
  if o.tempo then
    local fp = core.tempo_fingerprint(tl)
    if fp ~= link.tempo_fp or opts.force_tempo then
      write_tempo(proj, link.anchor, tl)
      link.tempo_fp = fp
      rep("Tempo map updated (" .. #tl.tempo .. " markers).")
    end
  end
  local _, anchor_qn = reaper.TimeMap_GetMeasureInfo(proj, link.anchor)

  -- regions + markers (always remove our old ones; recreate what is enabled)
  delete_marks(proj, link.regions, true)
  link.regions = o.regions and create_regions(proj, anchor_qn, tl) or {}
  delete_marks(proj, link.markers, false)
  link.markers = create_markers(proj, anchor_qn, tl, o)

  -- chords track
  local nchords = 0
  for _, e in ipairs(all_tagged_items(proj)) do
    if e.key == CHORD_KEY and not is_locked(e.item) then reaper.DeleteTrackMediaItem(e.track, e.item) end
  end
  if o.chords and #tl.chords > 0 then nchords = write_chords(proj, link, anchor_qn, tl) end

  -- MIDI tracks
  local total_notes = 0
  if o.midi then
    local target = {}
    for i, t in ipairs(tl.tracks) do
      local key = keys[i]
      local guid = link.map[key]
      if guid == nil then
        rep("New GP track '" .. key .. "' is not mapped (run Map tracks).")
      elseif guid ~= "skip" then
        local tr = (guid ~= "new") and R.find_track_by_guid(proj, guid) or nil
        if not tr then
          tr = R.create_track(proj, t.name, t.color)
          link.map[key] = reaper.GetTrackGUID(tr)
          if guid ~= "new" then rep("Track for '" .. key .. "' was missing - created a new one.") end
        end
        target[key] = tr
      end
    end

    local frozen = {}
    for _, e in ipairs(all_tagged_items(proj)) do
      if e.key ~= CHORD_KEY then
        if is_locked(e.item) then
          if target[e.key] == e.track then frozen[e.key] = true end
        else
          reaper.DeleteTrackMediaItem(e.track, e.item)
          if not target[e.key] then
            rep("Removed old GP item '" .. e.key .. "' (track skipped/remapped/no longer in GP).")
          end
        end
      end
    end

    for i, t in ipairs(tl.tracks) do
      local key = keys[i]
      local tr = target[key]
      if tr then
        if frozen[key] then
          rep("'" .. key .. "': GP item is locked -> skipped.")
        else
          total_notes = total_notes + write_item(proj, tr, anchor_qn, t, key, tl.length, o.lyrics)
        end
      end
    end

    local present = {}
    for _, k in ipairs(keys) do present[k] = true end
    for k, g in pairs(link.map) do
      if not present[k] and g ~= "skip" then rep("GP track '" .. k .. "' no longer exists in the GP file.") end
    end
  end

  link.sig = core.hash(raw)
  link.last_sync = os.date("%H:%M:%S")
  R.save_link(proj, link)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(proj, "GP-Link: Sync", -1)

  for _, w in ipairs(tl.warnings or {}) do rep("Note: " .. w) end
  local parts = { string.format("%d bars", #tl.bars) }
  if o.midi then parts[#parts + 1] = total_notes .. " notes" end
  if o.regions or o.section_markers then parts[#parts + 1] = #tl.sections .. " Sections" end
  if o.chords and nchords > 0 then parts[#parts + 1] = nchords .. " chords" end
  if o.text_markers and #tl.texts > 0 then parts[#parts + 1] = #tl.texts .. " text markers" end
  local head = string.format("[GP-Link %s] %s: %s.", os.date("%H:%M:%S"),
    link.file:match("[^\\/]+$") or link.file, table.concat(parts, ", "))
  table.insert(report, 1, head)
  local text = table.concat(report, "\n")
  if not opts.quiet then msg(text) end
  return text
end

---------------------------------------------------------------------------
-- Import / relink (import action, extension drag & drop)
---------------------------------------------------------------------------

-- file: path from drag & drop, or nil to ask (file dialog / keep current).
-- opts.anchor_time: project time of a drop -> default start measure.
-- opts.preset: "structure" -> MIDI/Lyrics unchecked by default.
-- Returns true if a sync happened.
function R.import(proj, file, opts)
  proj = proj or 0
  opts = opts or {}
  local link = R.load_link(proj)

  if file and not R.is_gp_file(file) then
    reaper.MB("Only Guitar Pro files (.gp, .gpx, .gp5) are supported:\n" .. file, "GP-Link", 0)
    return false
  end

  if link and file and file ~= link.file then
    local r = reaper.MB("This project is linked to:\n" .. link.file ..
      "\n\nReplace the link with:\n" .. file .. " ?", "GP-Link", 4)
    if r ~= 6 then return false end
  elseif link and not file then
    local r = reaper.MB("This project is linked to:\n" .. link.file ..
      "\n\nYes = choose another GP file\nNo = keep this file, choose parts/tracks again",
      "GP-Link", 3)
    if r == 2 then return false end
    if r == 7 then file = link.file end
  end

  if not file then
    file = R.choose_gp_file()
    if not file then return false end
  end

  local new_link = link or { map = {}, regions = {}, markers = {}, opts = R.default_opts(), countin = 0 }
  local _, tl = R.load_song(file, build_cfg(new_link))
  local res = R.import_dialog(proj, tl, file, link, opts.anchor_time, opts.preset)
  if not res then return false end

  local file_changed = (not link) or (link.file ~= file)
  local layout_changed = (new_link.anchor ~= res.anchor) or ((new_link.countin or 0) ~= res.countin)
  new_link.file = file
  new_link.anchor = res.anchor
  new_link.countin = res.countin
  new_link.map = res.map
  for k, v in pairs(res.opts) do new_link.opts[k] = v end
  if file_changed or layout_changed then new_link.tempo_fp = nil end
  R.save_link(proj, new_link)

  R.sync(proj, { mapped = true })
  return true
end

---------------------------------------------------------------------------
-- File watcher (auto-sync without the extension). Returns tick() for a defer loop.
-- Idempotent: skips the sync if the file content equals the last synced one.
---------------------------------------------------------------------------

function R.new_watcher(on_sync)
  local cfg = R.load_config()
  local interval = cfg.poll_interval or 1.0
  local watched_proj, watched_file, last_content, candidate
  local last_poll = 0
  local pending = false

  return function()
    local now = reaper.time_precise()
    if now - last_poll < interval then return end
    last_poll = now
    local proj = reaper.EnumProjects(-1)
    local link = R.load_link(proj)
    if not link then
      watched_proj, watched_file, last_content, candidate, pending = proj, nil, nil, nil, false
      return
    end
    local content = R.read_file(link.file)
    if proj ~= watched_proj or link.file ~= watched_file then
      watched_proj, watched_file, candidate = proj, link.file, nil
      last_content = content
      pending = content ~= nil
    elseif content and content ~= last_content then
      if content == candidate then pending, candidate = true, nil else candidate = content end
    end
    if pending and content then
      local recording = (reaper.GetPlayStateEx(proj) & 4) == 4
      if not recording then
        pending = false
        last_content = content
        if core.hash(content) ~= link.sig then
          local ok, res = pcall(R.sync, proj)
          if not ok then msg("[GP-Link] Sync failed: " .. tostring(res)) end
          if on_sync then on_sync(ok, res) end
        end
      end
    end
  end
end

return R
