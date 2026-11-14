-- GP-Link core: Guitar Pro 7/8 (.gp / score.gpif) -> musical timeline.
-- Pure Lua 5.4, no REAPER dependency (testable outside REAPER).
-- All positions are in quarter notes (QN) from the start of the song.

local M = {}

---------------------------------------------------------------------------
-- Minimal XML parser
---------------------------------------------------------------------------

local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function decode(s)
  if not s:find("&", 1, true) then return s end
  return (s:gsub("&(#?x?)(%w+);", function(kind, v)
    if kind == "#" then return utf8.char(tonumber(v)) end
    if kind == "#x" then return utf8.char(tonumber(v, 16)) end
    return ENT[v] or ("&" .. v .. ";")
  end))
end

local function new_node(tag, attr)
  return { tag = tag, attr = attr or {}, kids = {}, parts = {} }
end

function M.parse_xml(s)
  local root = new_node("#root")
  local stack = { root }
  local pos, len = 1, #s
  while pos <= len do
    local lt = s:find("<", pos, true)
    local top = stack[#stack]
    if not lt then
      top.parts[#top.parts + 1] = decode(s:sub(pos))
      break
    end
    if lt > pos then top.parts[#top.parts + 1] = decode(s:sub(pos, lt - 1)) end
    local c2 = s:sub(lt + 1, lt + 1)
    if s:sub(lt, lt + 3) == "<!--" then
      local e = s:find("-->", lt + 4, true) or len
      pos = e + 3
    elseif s:sub(lt, lt + 8) == "<![CDATA[" then
      local e = s:find("]]>", lt + 9, true) or (len + 1)
      top.parts[#top.parts + 1] = s:sub(lt + 9, e - 1)
      pos = e + 3
    elseif c2 == "?" then
      pos = (s:find("?>", lt + 2, true) or len) + 2
    elseif c2 == "!" then
      pos = (s:find(">", lt + 2, true) or len) + 1
    elseif c2 == "/" then
      local e = s:find(">", lt + 2, true) or len
      local node = table.remove(stack)
      node.text = table.concat(node.parts)
      node.parts = nil
      pos = e + 1
    else
      local name, p = s:match("^([%w_:%.%-]+)()", lt + 1)
      if not name then error("XML parse error at byte " .. lt) end
      local attr = {}
      while true do
        local k, _, v, np = s:match("^%s*([%w_:%.%-]+)%s*=%s*([\"'])(.-)%2()", p)
        if not k then break end
        attr[k] = decode(v)
        p = np
      end
      local close, np = s:match("^%s*(/?)>()", p)
      if not np then error("XML parse error in tag <" .. name .. "> at byte " .. lt) end
      local node = new_node(name, attr)
      top.kids[#top.kids + 1] = node
      if close == "/" then
        node.text = ""
        node.parts = nil
      else
        stack[#stack + 1] = node
      end
      pos = np
    end
  end
  -- close anything left open (tolerant)
  for i = #stack, 1, -1 do
    local n = stack[i]
    if n.parts then n.text = table.concat(n.parts); n.parts = nil end
  end
  return root
end

local function child(n, tag)
  if not n then return nil end
  for _, k in ipairs(n.kids) do if k.tag == tag then return k end end
  return nil
end

local function children(n, tag)
  local out = {}
  if not n then return out end
  for _, k in ipairs(n.kids) do if tag == nil or k.tag == tag then out[#out + 1] = k end end
  return out
end

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function text(n) return n and trim(n.text) or nil end

local function path(n, ...)
  for _, t in ipairs({ ... }) do n = child(n, t); if not n then return nil end end
  return n
end

local function words(s)
  local out = {}
  for w in (s or ""):gmatch("%S+") do out[#out + 1] = w end
  return out
end

-- <Properties><Property name="X">...</Property></Properties> -> map name -> node
local function props(n)
  local out = {}
  for _, p in ipairs(children(child(n, "Properties"), "Property")) do
    out[p.attr.name or "?"] = p
  end
  return out
end

M._xml = { child = child, children = children, text = text, path = path }

---------------------------------------------------------------------------
-- GPIF -> score model
---------------------------------------------------------------------------

local NOTE_VALUE_QN = {
  DoubleWhole = 8, Whole = 4, Half = 2, Quarter = 1, Eighth = 0.5,
  ["16th"] = 0.25, ["32nd"] = 0.125, ["64th"] = 0.0625, ["128th"] = 0.03125, ["256th"] = 0.015625,
}

-- GP tempo reference unit -> factor to quarter-note BPM
local TEMPO_UNIT = { [1] = 0.5, [2] = 1, [3] = 1.5, [4] = 2, [5] = 3 }

local function index_by_id(section)
  local t = {}
  for _, e in ipairs(section and section.kids or {}) do
    if e.attr.id then t[e.attr.id] = e end
  end
  return t
end

-- Guitar Pro 6 drum notes store a kit element and a variation instead of a MIDI number.
-- Element order of the GP6 drum kit; values are the GM notes per variation (0, 1, 2).
local GP6_DRUMS = {
  [0] = { 35, 35, 35 },  -- kick
  { 38, 40, 37 },        -- snare (normal, rim shot, side stick)
  { 56, 56, 56 },        -- cowbell low
  { 56, 56, 56 },        -- cowbell medium
  { 56, 56, 56 },        -- cowbell high
  { 41, 41, 41 },        -- tom very low
  { 45, 45, 45 },        -- tom low
  { 47, 47, 47 },        -- tom medium
  { 48, 48, 48 },        -- tom high
  { 50, 50, 50 },        -- tom very high
  { 42, 42, 46 },        -- hi-hat (closed, half, open)
  { 44, 44, 44 },        -- pedal hi-hat
  { 57, 57, 57 },        -- crash medium
  { 49, 49, 49 },        -- crash high
  { 55, 55, 55 },        -- splash
  { 51, 59, 53 },        -- ride (middle, edge, bell)
  { 52, 52, 52 },        -- china
}
M.GP6_DRUMS = GP6_DRUMS

function M.parse_gpif(xml)
  local doc = M.parse_xml(xml)
  local gp = child(doc, "GPIF")
  if not gp then error("No GPIF data found in the Guitar Pro file.") end

  local score = {
    version = text(child(gp, "GPVersion")) or "?",
    title = text(path(gp, "Score", "Title")) or "",
    artist = text(path(gp, "Score", "Artist")) or "",
    tracks = {}, masterbars = {}, tempos = {}, warnings = {},
  }

  -- Rhythms
  local rhythms = {}
  for id, r in pairs(index_by_id(child(gp, "Rhythms"))) do
    local qn = NOTE_VALUE_QN[text(child(r, "NoteValue"))] or 1
    local dot = child(r, "AugmentationDot")
    local dots = dot and tonumber(dot.attr.count) or 0
    if dots == 1 then qn = qn * 1.5 elseif dots == 2 then qn = qn * 1.75 elseif dots >= 3 then qn = qn * 1.875 end
    local tup = child(r, "PrimaryTuplet")
    if tup then
      local num, den = tonumber(tup.attr.num), tonumber(tup.attr.den)
      if num and den and num > 0 then qn = qn * den / num end
    end
    local tup2 = child(r, "SecondaryTuplet")
    if tup2 then
      local num, den = tonumber(tup2.attr.num), tonumber(tup2.attr.den)
      if num and den and num > 0 then qn = qn * den / num end
    end
    rhythms[id] = qn
  end

  -- Notes
  local notes = {}
  for id, n in pairs(index_by_id(child(gp, "Notes"))) do
    local p = props(n)
    local note = { id = id }
    local midi = p.Midi and text(child(p.Midi, "Number"))
    note.midi = tonumber(midi)
    note.string = p.String and tonumber(text(child(p.String, "String")))
    note.fret = p.Fret and tonumber(text(child(p.Fret, "Fret")))
    if not note.midi and p.Element then -- GP6 drums
      local el = tonumber(text(child(p.Element, "Element")))
      local var = p.Variation and tonumber(text(child(p.Variation, "Variation"))) or 0
      local row = el and GP6_DRUMS[el]
      note.midi = row and (row[var + 1] or row[1])
    end
    if not note.midi and not note.fret and (p.Tone or p.Octave) then -- GP6 keyboard notes
      local tone = p.Tone and tonumber(text(child(p.Tone, "Step"))) or 0
      local oct = p.Octave and tonumber(text(child(p.Octave, "Number"))) or 0
      note.midi = oct * 12 + tone
    end
    note.art = tonumber(text(child(n, "InstrumentArticulation")))
    local tie = child(n, "Tie")
    if tie then
      note.tie_origin = tie.attr.origin == "true"
      note.tie_dest = tie.attr.destination == "true"
    end
    local acc = tonumber(text(child(n, "Accent")))
    if acc then
      note.staccato = (acc & 1) ~= 0
      if (acc & 4) ~= 0 then note.accent = 2 elseif (acc & 8) ~= 0 then note.accent = 1 end
    end
    note.ghost = child(n, "AntiAccent") ~= nil
    note.letring = child(n, "LetRing") ~= nil
    note.palm = p.PalmMuted ~= nil
    note.dead = p.Muted ~= nil
    note.harmonic = p.Harmonic ~= nil or p.HarmonicType ~= nil
    note.slide = p.Slide ~= nil
    note.bend = p.Bended ~= nil
    notes[id] = note
  end

  -- Beats
  local beats = {}
  for id, b in pairs(index_by_id(child(gp, "Beats"))) do
    local rref = child(b, "Rhythm")
    local ft = text(child(b, "FreeText"))
    beats[id] = {
      dur = rhythms[rref and rref.attr.ref] or 1,
      dyn = text(child(b, "Dynamic")) or "MF",
      grace = text(child(b, "GraceNotes")), -- "BeforeBeat" / "OnBeat" / nil
      notes = words(text(child(b, "Notes"))),
      chord = text(child(b, "Chord")),      -- id into the track's chord/diagram collection
      free_text = (ft and ft ~= "") and ft or nil,
    }
  end

  local voices = {}
  for id, v in pairs(index_by_id(child(gp, "Voices"))) do
    voices[id] = words(text(child(v, "Beats")))
  end

  local bars = {}
  for id, b in pairs(index_by_id(child(gp, "Bars"))) do
    local vs = {}
    for _, v in ipairs(words(text(child(b, "Voices")))) do
      if v ~= "-1" then vs[#vs + 1] = v end
    end
    bars[id] = { voices = vs, simile = text(child(b, "SimileMark")) }
  end

  score._notes, score._beats, score._voices, score._bars = notes, beats, voices, bars

  -- Tracks (order of MasterTrack/Tracks, fallback document order)
  local track_nodes = index_by_id(child(gp, "Tracks"))
  local order = words(text(path(gp, "MasterTrack", "Tracks")))
  if #order == 0 then
    for _, t in ipairs(children(child(gp, "Tracks"), "Track")) do order[#order + 1] = t.attr.id end
  end
  -- staff columns in MasterBar/Bars follow the track list order (all staves of a track in a row)
  -- GP7/8 lists the staves of a track; GP6 does not, so keyboard-like tracks (no tuning, no drums)
  -- share the columns that are left over (piano/synth tracks have two staves there).
  local function gp6_kind(t)
    if child(t, "Staves") then return nil end
    local inst = child(t, "Instrument")
    local gm = child(t, "GeneralMidi")
    if (inst and inst.attr.ref == "drmkt") or (gm and text(child(gm, "PrimaryChannel")) == "9") then return "drums" end
    if props(t).Tuning then return "strings" end
    return "keys"
  end
  local extra_staves = {}
  do
    local first_mb = child(child(gp, "MasterBars"), "MasterBar")
    local ncols = first_mb and #words(text(child(first_mb, "Bars"))) or 0
    local used, keys = 0, {}
    for _, tid in ipairs(order) do
      local t = track_nodes[tid]
      if t then
        used = used + math.max(1, #children(child(t, "Staves"), "Staff"))
        if gp6_kind(t) == "keys" then keys[#keys + 1] = tid end
      end
    end
    local extra = ncols - used
    if extra > 0 and #keys > 0 then
      local each, rest = extra // #keys, extra % #keys
      for k, tid in ipairs(keys) do extra_staves[tid] = each + (k <= rest and 1 or 0) end
    end
  end
  local col = 0
  for i, tid in ipairs(order) do
    local t = track_nodes[tid]
    if t then
      local iset = child(t, "InstrumentSet")
      local itype = text(child(iset, "Type")) or ""
      local kind6 = gp6_kind(t)
      local is_drums = itype == "drumKit" or kind6 == "drums"
      -- flattened articulation list (InstrumentArticulation index -> output midi)
      local art_out = {}
      local idx = 0
      for _, el in ipairs(children(child(iset, "Elements"), "Element")) do
        for _, a in ipairs(children(child(el, "Articulations"), "Articulation")) do
          art_out[idx] = tonumber(text(child(a, "OutputMidiNumber")))
          idx = idx + 1
        end
      end
      local staves = children(child(t, "Staves"), "Staff")
      if kind6 then staves = { t } end -- GP6: tuning, capo and diagrams sit in the track's own Properties
      local nstaves = math.max(1, #staves) + (extra_staves[tid] or 0)
      local staff_info = {}
      local chord_names = {}
      for s = 1, nstaves do
        local sp = props(staves[s])
        for _, coll in ipairs({ "DiagramCollection", "ChordCollection" }) do
          for _, item in ipairs(children(child(sp[coll], "Items"), "Item")) do
            if item.attr.id and item.attr.name and item.attr.name ~= "" then
              chord_names[item.attr.id] = chord_names[item.attr.id] or item.attr.name
            end
          end
        end
        local tuning = sp.Tuning and words(text(child(sp.Tuning, "Pitches"))) or {}
        for k, v in ipairs(tuning) do tuning[k] = tonumber(v) end
        local capo = sp.CapoFret and tonumber(text(child(sp.CapoFret, "Fret"))) or 0
        staff_info[s] = { col = col + (s - 1), tuning = tuning, capo = capo }
      end
      col = col + nstaves
      local lyrics = {}
      for _, line in ipairs(children(child(t, "Lyrics"), "Line")) do
        local lt = text(child(line, "Text")) or ""
        if lt ~= "" then
          lyrics[#lyrics + 1] = { text = lt, offset = tonumber(text(child(line, "Offset"))) or 0 }
        end
      end
      local color = words(text(child(t, "Color")))
      local mc = child(t, "MidiConnection") or child(t, "GeneralMidi")
      score.tracks[#score.tracks + 1] = {
        index = i,
        id = tid,
        name = text(child(t, "Name")) or ("Track " .. i),
        instrument = text(child(iset, "Name")) or (child(t, "Instrument") and child(t, "Instrument").attr.ref) or "",
        is_drums = is_drums,
        art_out = art_out,
        staves = staff_info,
        color = (#color >= 3) and { tonumber(color[1]), tonumber(color[2]), tonumber(color[3]) } or nil,
        gp_channel = mc and tonumber(text(child(mc, "PrimaryChannel"))) or 0,
        chord_names = chord_names,
        lyrics = lyrics,
      }
    end
  end

  -- Master bars
  for i, mb in ipairs(children(child(gp, "MasterBars"), "MasterBar")) do
    local num, den = (text(child(mb, "Time")) or "4/4"):match("(%d+)/(%d+)")
    num, den = tonumber(num) or 4, tonumber(den) or 4
    local m = {
      index = i,
      num = num, den = den, qn = num * 4 / den,
      bars = words(text(child(mb, "Bars"))),
    }
    local sec = child(mb, "Section")
    if sec then
      local letter, txt = text(child(sec, "Letter")) or "", text(child(sec, "Text")) or ""
      m.section = (txt ~= "" and txt) or (letter ~= "" and letter) or ("Part " .. i)
      m.section_letter = letter
    end
    local rep = child(mb, "Repeat")
    if rep then
      m.repeat_start = rep.attr.start == "true"
      m.repeat_end = rep.attr["end"] == "true"
      m.repeat_count = tonumber(rep.attr.count) or 2
      if m.repeat_count < 2 then m.repeat_count = 2 end
    end
    local alt = text(child(mb, "AlternateEndings"))
    if alt and alt ~= "" then
      m.alt = {}
      for _, w in ipairs(words(alt)) do m.alt[tonumber(w)] = true end
    end
    local dirs = child(mb, "Directions")
    if dirs then
      m.has_directions = true
      m.targets, m.jumps = {}, {}
      for _, d in ipairs(children(dirs, "Target")) do m.targets[#m.targets + 1] = text(d) end
      for _, d in ipairs(children(dirs, "Jump")) do m.jumps[#m.jumps + 1] = text(d) end
    end
    if child(mb, "Fermatas") then m.has_fermata = true end
    local key = child(mb, "Key")
    if key then
      m.key_count = tonumber(text(child(key, "AccidentalCount"))) or 0
      m.key_mode = text(child(key, "Mode")) or "Major"
    end
    score.masterbars[i] = m
  end

  -- Tempo automations
  for _, a in ipairs(children(path(gp, "MasterTrack", "Automations"), "Automation")) do
    if text(child(a, "Type")) == "Tempo" then
      local v = words(text(child(a, "Value")))
      local bpm = tonumber(v[1]) or 120
      local unit = tonumber(v[2]) or 2
      score.tempos[#score.tempos + 1] = {
        bar = (tonumber(text(child(a, "Bar"))) or 0) + 1, -- 1-based master bar
        pos = tonumber(text(child(a, "Position"))) or 0,  -- ratio 0..1 inside bar
        bpm = bpm * (TEMPO_UNIT[unit] or 1),
        linear = text(child(a, "Linear")) == "true",
      }
    end
  end
  table.sort(score.tempos, function(a, b)
    if a.bar ~= b.bar then return a.bar < b.bar end
    return a.pos < b.pos
  end)

  return score
end

---------------------------------------------------------------------------
-- Playback order (repeats + alternate endings)
---------------------------------------------------------------------------

function M.unroll(score)
  local mbs = score.masterbars
  local out = {}
  local i, n = 1, #mbs
  local rstart, pass = 1, 1
  local loops = {}
  local guard = 0
  local warned_dir = false
  while i <= n do
    guard = guard + 1
    if guard > 100000 then break end
    local m = mbs[i]
    if m.repeat_start and i ~= rstart then rstart, pass = i, 1 end
    if m.has_directions and not warned_dir then
      warned_dir = true
      score.warnings[#score.warnings + 1] =
        "Jumps (D.S./D.C./Coda) are not followed yet - bars play linearly."
    end
    local play = (not m.alt) or m.alt[pass]
    if play then out[#out + 1] = i end
    if play and m.repeat_end then
      local done = loops[i] or 1
      if done < m.repeat_count then
        loops[i] = done + 1
        pass = done + 1
        i = rstart
        goto continue
      else
        loops[i] = nil
        pass = 1
      end
    end
    i = i + 1
    ::continue::
  end
  return out
end

---------------------------------------------------------------------------
-- Timeline
---------------------------------------------------------------------------

local DYN_VEL = { PPP = 16, PP = 33, P = 49, MP = 64, MF = 80, F = 96, FF = 112, FFF = 127 }

local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

-- technique of a note for keyswitch purposes (priority order)
local function technique(note)
  if note.dead then return "Muted" end
  if note.harmonic then return "Harmonic" end
  if note.palm then return "PalmMuted" end
  return "Normal"
end

-- cfg (all optional):
--   drum_channel (1-16), channel (1-16), use_gp_channels (bool),
--   ghost_factor, accent_add, heavy_accent_add, dead_note_velocity,
--   keyswitches = { [trackName] = { Normal=, PalmMuted=, Muted=, Harmonic=, lead_qn= } }
function M.build(score, cfg)
  cfg = cfg or {}
  local played = M.unroll(score)
  local tl = {
    bars = {},        -- played bars: { mb=, qn=, len=, num=, den= }
    tempo = {},       -- { qn=, bar=(0-based played index), beat_frac=, bpm=, linear=, num=, den= }
    sections = {},    -- { qn=, qn_end=, name= }
    tracks = {},      -- per score track: { name=, notes = { {s=,e=,p=,v=,c=} } }
    length = 0,
    warnings = score.warnings,
  }

  -- bar grid
  local qn = 0
  for k, mbi in ipairs(played) do
    local m = score.masterbars[mbi]
    tl.bars[k] = { mb = mbi, qn = qn, len = m.qn, num = m.num, den = m.den }
    qn = qn + m.qn
  end
  tl.length = qn

  -- tempo + time signature events
  local tempo_by_bar = {}
  for _, t in ipairs(score.tempos) do
    tempo_by_bar[t.bar] = tempo_by_bar[t.bar] or {}
    table.insert(tempo_by_bar[t.bar], t)
  end
  local cur_bpm = (score.tempos[1] and score.tempos[1].bar == 1 and score.tempos[1].pos == 0)
    and score.tempos[1].bpm or 120
  local prev_num, prev_den
  for k, b in ipairs(tl.bars) do
    local m = score.masterbars[b.mb]
    local sig_change = (m.num ~= prev_num or m.den ~= prev_den)
    local list = tempo_by_bar[b.mb] or {}
    local at_start = nil
    for _, t in ipairs(list) do if t.pos == 0 then at_start = t end end
    if k == 1 or sig_change or at_start then
      if at_start then cur_bpm = at_start.bpm end
      tl.tempo[#tl.tempo + 1] = {
        qn = b.qn, bar = k - 1, beat_frac = 0, bpm = cur_bpm,
        linear = at_start and at_start.linear or false,
        num = sig_change and m.num or nil, den = sig_change and m.den or nil,
      }
    end
    for _, t in ipairs(list) do
      if t.pos > 0 then
        cur_bpm = t.bpm
        tl.tempo[#tl.tempo + 1] = {
          qn = b.qn + t.pos * b.len, bar = k - 1, beat_frac = t.pos, bpm = t.bpm, linear = t.linear,
        }
      end
    end
    prev_num, prev_den = m.num, m.den
  end

  -- sections
  for k, b in ipairs(tl.bars) do
    local m = score.masterbars[b.mb]
    if m.section then
      if #tl.sections > 0 then tl.sections[#tl.sections].qn_end = b.qn end
      tl.sections[#tl.sections + 1] = { qn = b.qn, name = m.section, base = m.section, letter = m.section_letter }
    end
  end
  if #tl.sections > 0 then tl.sections[#tl.sections].qn_end = tl.length end
  -- number repeated sections: "Chorus 1", "Chorus 2"
  if cfg.number_sections ~= false then
    local total, seen = {}, {}
    for _, s in ipairs(tl.sections) do total[s.base] = (total[s.base] or 0) + 1 end
    for _, s in ipairs(tl.sections) do
      if total[s.base] > 1 then
        seen[s.base] = (seen[s.base] or 0) + 1
        s.name = s.base .. " " .. seen[s.base]
      end
    end
  end

  -- text markers: directions (Segno/Coda/D.S. ...) and key changes
  tl.texts = {}
  local prev_key
  for k, b in ipairs(tl.bars) do
    local m = score.masterbars[b.mb]
    for _, t in ipairs(m.targets or {}) do
      tl.texts[#tl.texts + 1] = { qn = b.qn, text = M.DIRECTION_NAMES[t] or t, kind = "direction" }
    end
    for _, j in ipairs(m.jumps or {}) do
      tl.texts[#tl.texts + 1] = { qn = b.qn + b.len, text = M.DIRECTION_NAMES[j] or j, kind = "direction" }
    end
    if m.key_count then
      local key = m.key_count .. m.key_mode
      if key ~= prev_key then
        tl.texts[#tl.texts + 1] = { qn = b.qn, text = "Key: " .. M.key_name(m.key_count, m.key_mode), kind = "key" }
        prev_key = key
      end
    end
  end
  tl.chords = {}

  -- first played occurrence of each master bar (lyrics follow the score, not the repeats)
  local first_occ, seen_mb = {}, {}
  for k, b in ipairs(tl.bars) do
    first_occ[k] = not seen_mb[b.mb]
    seen_mb[b.mb] = true
  end
  local text_seen = {}

  -- notes
  local notes, beats, voices, bars = score._notes, score._beats, score._voices, score._bars
  local ghost_factor = cfg.ghost_factor or 0.6
  local accent_add = cfg.accent_add or 15
  local heavy_add = cfg.heavy_accent_add or 25
  local dead_vel = cfg.dead_note_velocity

  for _, tr in ipairs(score.tracks) do
    local chan
    if tr.is_drums then chan = (cfg.drum_channel or 10) - 1
    elseif cfg.use_gp_channels then chan = tr.gp_channel or 0
    else chan = (cfg.channel or 1) - 1 end
    chan = clamp(chan, 0, 15)

    local out = {}
    local ks_cfg = cfg.keyswitches and (cfg.keyswitches[tr.name] or cfg.keyswitches[tr.instrument])
    local ks_events = {}
    local track_chords = {}
    local lyric_slots = {}

    for si, staff in ipairs(tr.staves) do
      local open = {} -- tie bookkeeping: key -> note
      local src_hist = {} -- played index -> bar id actually used (for simile)
      for k, b in ipairs(tl.bars) do
        local mb = score.masterbars[b.mb]
        local bar_id = mb.bars[staff.col + 1]
        local bar = bar_id and bars[bar_id]
        -- simile marks: repeat content of previous bar(s)
        if bar and bar.simile then
          local back = (bar.simile == "Simple") and 1 or 2
          local src = src_hist[k - back]
          if src then bar_id = src; bar = bars[src] end
        end
        src_hist[k] = bar_id
        if bar then
          for vi, vid in ipairs(bar.voices) do
            local pos = b.qn
            local shift = 0
            for _, bid in ipairs(voices[vid] or {}) do
              local beat = beats[bid]
              if beat then
                local dur = beat.dur
                local start, len
                if beat.grace == "BeforeBeat" then
                  start, len = math.max(0, pos - dur), dur
                elseif beat.grace == "OnBeat" then
                  start, len = pos, dur
                  shift = shift + dur
                else
                  start, len = pos + shift, math.max(dur - shift, dur * 0.25)
                  shift = 0
                end
                local base_vel = DYN_VEL[beat.dyn] or 80
                if si == 1 then
                  if beat.chord and tr.chord_names[beat.chord] then
                    track_chords[#track_chords + 1] = { qn = start, name = tr.chord_names[beat.chord] }
                  end
                  if beat.free_text then
                    local key = string.format("%.4f|%s", start, beat.free_text)
                    if not text_seen[key] then
                      text_seen[key] = true
                      tl.texts[#tl.texts + 1] = { qn = start, text = beat.free_text, kind = "text" }
                    end
                  end
                  if vi == 1 and not beat.grace and #beat.notes > 0 and first_occ[k] then
                    local onset = false
                    for _, nid in ipairs(beat.notes) do
                      local n = notes[nid]
                      if n and not n.tie_dest then onset = true break end
                    end
                    if onset then lyric_slots[#lyric_slots + 1] = { qn = start, mb = b.mb } end
                  end
                end
                for _, nid in ipairs(beat.notes) do
                  local n = notes[nid]
                  if n then
                    local pitch
                    if tr.is_drums then
                      pitch = (n.art and tr.art_out[n.art]) or n.midi
                    else
                      pitch = n.midi
                      if not pitch and n.string and n.fret and staff.tuning[n.string + 1] then
                        pitch = staff.tuning[n.string + 1] + n.fret + (staff.capo or 0)
                      end
                    end
                    if pitch then
                      pitch = clamp(math.floor(pitch + 0.5), 0, 127)
                      local key = vi .. ":" .. (n.string or pitch) .. ":" .. pitch
                      local nlen = len
                      if n.staccato then nlen = nlen * 0.5 end
                      if n.tie_dest and open[key] then
                        open[key].e = start + nlen
                        if not n.tie_origin then open[key] = nil end
                      else
                        local v = (n.dyn and DYN_VEL[n.dyn]) or base_vel -- GP3-5: dynamics per note
                        if n.ghost then v = v * ghost_factor end
                        if n.accent == 1 then v = v + accent_add elseif n.accent == 2 then v = v + heavy_add end
                        if n.dead and dead_vel then v = dead_vel end
                        local ev = { s = start, e = start + nlen, p = pitch, v = clamp(math.floor(v + 0.5), 1, 127), c = chan }
                        out[#out + 1] = ev
                        open[key] = ev
                        if ks_cfg and not tr.is_drums then
                          ks_events[#ks_events + 1] = { s = start, tech = technique(n) }
                        end
                      end
                    end
                  end
                end
                if beat.grace ~= "BeforeBeat" and beat.grace ~= "OnBeat" then pos = pos + dur end
              end
            end
          end
        end
      end
    end

    -- keyswitches: emit on technique change
    if ks_cfg then
      table.sort(ks_events, function(a, b) return a.s < b.s end)
      local lead = ks_cfg.lead_qn or (1 / 32)
      local cur = nil
      local last_s = -1
      for _, e in ipairs(ks_events) do
        if e.s ~= last_s or e.tech ~= cur then
          if e.tech ~= cur then
            local ksnote = ks_cfg[e.tech] or ks_cfg.Normal
            if ksnote then
              local s = math.max(0, e.s - lead)
              out[#out + 1] = { s = s, e = s + lead * 0.5, p = ksnote, v = 100, c = chan, ks = true }
            end
            cur = e.tech
          end
          last_s = e.s
        end
      end
    end

    -- trim overlapping notes of same channel+pitch
    table.sort(out, function(a, b)
      if a.s ~= b.s then return a.s < b.s end
      return a.p < b.p
    end)
    local last = {}
    local clean = {}
    for _, ev in ipairs(out) do
      local key = ev.c * 128 + ev.p
      local prev = last[key]
      if prev and prev.e > ev.s then prev.e = ev.s end
      last[key] = ev
      clean[#clean + 1] = ev
    end
    local final = {}
    for _, ev in ipairs(clean) do
      if ev.e - ev.s > 1e-6 then final[#final + 1] = ev end
    end

    -- lyrics: syllables onto note onsets (staff 1, voice 1) from the line's start bar
    local lyr = {}
    if #tr.lyrics > 0 and #lyric_slots > 0 then
      table.sort(lyric_slots, function(a, b) return a.qn < b.qn end)
      local used = {}
      for _, line in ipairs(tr.lyrics) do
        local tokens = M.lyric_tokens(line.text)
        local ti = 1
        for si2, slot in ipairs(lyric_slots) do
          if ti > #tokens then break end
          if slot.mb - 1 >= line.offset and not used[si2] then
            used[si2] = true
            lyr[#lyr + 1] = { qn = slot.qn, text = tokens[ti] }
            ti = ti + 1
          end
        end
      end
      table.sort(lyr, function(a, b) return a.qn < b.qn end)
    end

    if #tl.chords == 0 and #track_chords > 0 then
      table.sort(track_chords, function(a, b) return a.qn < b.qn end)
      tl.chords = track_chords
      tl.chords_source = tr.name
    end

    tl.tracks[#tl.tracks + 1] = {
      name = tr.name, instrument = tr.instrument, is_drums = tr.is_drums,
      color = tr.color, notes = final, lyrics = lyr,
    }
  end

  table.sort(tl.texts, function(a, b) return a.qn < b.qn end)

  -- count-in: empty bars before the song (same meter/tempo as bar 1)
  local countin = math.floor(tonumber(cfg.countin) or 0)
  if countin > 0 and #tl.bars > 0 then
    local first = tl.bars[1]
    local off = countin * first.len
    for _, b in ipairs(tl.bars) do b.qn = b.qn + off end
    for i = countin, 1, -1 do
      table.insert(tl.bars, 1, { mb = nil, qn = (i - 1) * first.len, len = first.len, num = first.num, den = first.den, countin = true })
    end
    for _, t in ipairs(tl.tempo) do
      t.qn = t.qn + off
      t.bar = t.bar + countin
    end
    if tl.tempo[1] and tl.tempo[1].bar == countin and tl.tempo[1].beat_frac == 0 then
      -- move the initial tempo/meter marker to the count-in start, keep a plain marker at bar 1
      local t1 = tl.tempo[1]
      table.insert(tl.tempo, 1, { qn = 0, bar = 0, beat_frac = 0, bpm = t1.bpm, linear = false, num = t1.num, den = t1.den })
      t1.num, t1.den = nil, nil
    end
    for _, s in ipairs(tl.sections) do s.qn = s.qn + off; s.qn_end = s.qn_end + off end
    if cfg.countin_region ~= false then
      table.insert(tl.sections, 1, { qn = 0, qn_end = off, name = "Count-in", base = "Count-in", letter = "" })
    end
    for _, t in ipairs(tl.texts) do t.qn = t.qn + off end
    for _, c in ipairs(tl.chords) do c.qn = c.qn + off end
    for _, tr in ipairs(tl.tracks) do
      for _, n in ipairs(tr.notes) do n.s = n.s + off; n.e = n.e + off end
      for _, l in ipairs(tr.lyrics) do l.qn = l.qn + off end
    end
    tl.length = tl.length + off
    tl.countin = countin
  end

  return tl
end

M.DIRECTION_NAMES = {
  Segno = "Segno", SegnoSegno = "Segno Segno", Coda = "Coda", DoubleCoda = "Double Coda", Fine = "Fine",
  DaCapo = "D.C.", DaCapoAlCoda = "D.C. al Coda", DaCapoAlDoubleCoda = "D.C. al Double Coda",
  DaCapoAlFine = "D.C. al Fine", DaSegno = "D.S.", DaSegnoAlCoda = "D.S. al Coda",
  DaSegnoAlDoubleCoda = "D.S. al Double Coda", DaSegnoAlFine = "D.S. al Fine",
  DaSegnoSegno = "D.S.S.", DaSegnoSegnoAlCoda = "D.S.S. al Coda",
  DaSegnoSegnoAlDoubleCoda = "D.S.S. al Double Coda", DaSegnoSegnoAlFine = "D.S.S. al Fine",
  DaCoda = "To Coda", DaDoubleCoda = "To Double Coda",
}

local KEY_MAJOR = { "Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#" }
local KEY_MINOR = { "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#", "G#", "D#", "A#" }

function M.key_name(count, mode)
  local i = clamp(math.floor(count or 0), -7, 7) + 8
  if mode == "Minor" then return KEY_MINOR[i] .. " minor" end
  return KEY_MAJOR[i] .. " major"
end

-- GP lyrics: words separated by whitespace, syllables by '-', '+' joins words on one note
function M.lyric_tokens(s)
  local out = {}
  for word in s:gsub("[\r\n]", " "):gmatch("%S+") do
    local parts = {}
    for syl in (word .. "-"):gmatch("([^%-]*)%-") do parts[#parts + 1] = syl end
    for i, syl in ipairs(parts) do
      if syl ~= "" then
        syl = syl:gsub("%+", " ")
        out[#out + 1] = (i < #parts and parts[i + 1] ~= nil) and (syl .. "-") or syl
      end
    end
  end
  return out
end

-- Stable fingerprint of tempo/time-signature map (to avoid rewriting unchanged maps)
function M.tempo_fingerprint(tl)
  local parts = {}
  for _, t in ipairs(tl.tempo) do
    parts[#parts + 1] = string.format("%d:%.4f:%.3f:%s:%s:%s", t.bar, t.beat_frac, t.bpm,
      tostring(t.linear), tostring(t.num), tostring(t.den))
  end
  parts[#parts + 1] = string.format("len=%.4f", tl.length)
  return table.concat(parts, "|")
end

-- FNV-1a 32 bit over a string (cheap content signature)
function M.hash(s)
  local h = 2166136261
  for i = 1, #s do
    h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff
  end
  return string.format("%08x:%d", h, #s)
end

return M
