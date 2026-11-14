-- GP-Link: older Guitar Pro formats
--   * Guitar Pro 5 (.gp5): binary format -> the same score model as gplink_core.parse_gpif
--   * Guitar Pro 6 (.gpx): compressed container (BCFZ/BCFS) holding score.gpif
-- Pure Lua 5.3+, no REAPER API.
local F = {}

---------------------------------------------------------------------------
-- byte reader (little endian)
---------------------------------------------------------------------------

local function reader(data)
  local r = { pos = 1 }
  local function need(n)
    if r.pos + n - 1 > #data then error("Unexpected end of the Guitar Pro file (corrupt or unsupported).", 0) end
  end
  function r.u8() need(1); local v = data:byte(r.pos); r.pos = r.pos + 1; return v end
  function r.i8() local v = r.u8(); return v >= 128 and v - 256 or v end
  function r.bool() return r.u8() ~= 0 end
  function r.i16() need(2); local v = string.unpack("<i2", data, r.pos); r.pos = r.pos + 2; return v end
  function r.i32() need(4); local v = string.unpack("<i4", data, r.pos); r.pos = r.pos + 4; return v end
  function r.f64() need(8); local v = string.unpack("<d", data, r.pos); r.pos = r.pos + 8; return v end
  function r.skip(n) need(n); r.pos = r.pos + n end
  function r.bytes(n) need(n); local s = data:sub(r.pos, r.pos + n - 1); r.pos = r.pos + n; return s end
  -- byte length + fixed-size field
  function r.byte_str(size)
    local len = r.u8()
    local s = r.bytes(size)
    return s:sub(1, math.min(len, size))
  end
  -- int length + data
  function r.int_str()
    local n = r.i32()
    if n < 0 or n > 1e7 then error("Corrupt string in the Guitar Pro file.", 0) end
    return r.bytes(n)
  end
  -- int (len+1) + byte length + data
  function r.int_byte_str()
    local n = r.i32()
    if n <= 0 then return "" end
    return r.byte_str(n - 1)
  end
  return r
end

-- Windows-1252 -> UTF-8 (GP5 strings)
local CP1252 = {
  [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020,
  [0x87] = 0x2021, [0x88] = 0x02C6, [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
  [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C, [0x94] = 0x201D, [0x95] = 0x2022,
  [0x96] = 0x2013, [0x97] = 0x2014, [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
  [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}
local function utf8_from_cp1252(s)
  if not s:find("[\128-\255]") then return s end
  return (s:gsub("[\128-\255]", function(c)
    local b = c:byte()
    return utf8.char(CP1252[b] or b)
  end))
end

---------------------------------------------------------------------------
-- Guitar Pro 5
---------------------------------------------------------------------------

local DYN_NAMES = { "PPP", "PP", "P", "MP", "MF", "F", "FF", "FFF" }
local function dyn_name(v) -- GP velocity step 1..8
  return DYN_NAMES[math.max(1, math.min(8, v))]
end

local TUPLET_TIMES = { [3] = 2, [5] = 4, [6] = 4, [7] = 4, [9] = 8, [10] = 8, [11] = 8, [12] = 8, [13] = 8 }

-- GP5 musical directions (header) -> GPIF names used by gplink_core
local SIGNS = { "Coda", "DoubleCoda", "Segno", "SegnoSegno", "Fine" }
local JUMPS = {
  "DaCapo", "DaCapoAlCoda", "DaCapoAlDoubleCoda", "DaCapoAlFine",
  "DaSegno", "DaSegnoAlCoda", "DaSegnoAlDoubleCoda", "DaSegnoAlFine",
  "DaSegnoSegno", "DaSegnoSegnoAlCoda", "DaSegnoSegnoAlDoubleCoda", "DaSegnoSegnoAlFine",
  "DaCoda", "DaDoubleCoda",
}

local VERSIONS = { ["FICHIER GUITAR PRO v5.00"] = 500, ["FICHIER GUITAR PRO v5.10"] = 510 }

-- binary Guitar Pro file (3, 4 or 5)?
function F.is_gp_binary(data)
  local len = data:byte(1)
  return len ~= nil and len <= 30 and data:sub(2, 19) == "FICHIER GUITAR PRO"
end

function F.parse_gp5(data)
  local r = reader(data)
  local vstr = r.byte_str(30)
  local ver = VERSIONS[vstr]
  if not ver then
    error("This file was saved by an older Guitar Pro (" .. vstr .. ").\n" ..
      "GP-Link reads Guitar Pro 5 and newer: open it in Guitar Pro and save it as .gp5 or .gp.", 0)
  end
  local v500 = ver == 500

  local score = {
    version = vstr, title = "", artist = "",
    tracks = {}, masterbars = {}, tempos = {}, warnings = {},
  }
  local notes, beats, voices, bars = {}, {}, {}, {}
  score._notes, score._beats, score._voices, score._bars = notes, beats, voices, bars

  -- info
  local info = {}
  for i = 1, 9 do info[i] = utf8_from_cp1252(r.int_byte_str()) end
  score.title, score.artist = info[1], info[3]
  for _ = 1, r.i32() do r.int_byte_str() end -- notice lines

  local lyrics_track, lyric_lines = r.i32(), {}
  for _ = 1, 5 do
    local start = r.i32()
    local txt = utf8_from_cp1252(r.int_str())
    if txt:find("%S") then lyric_lines[#lyric_lines + 1] = { text = txt, offset = math.max(0, start - 1) } end
  end

  if not v500 then r.skip(4 + 4 + 11) end           -- RSE master effect (volume, ?, equalizer)
  r.skip(4 * 2 + 4 * 4 + 4 + 2)                     -- page setup: size, margins, proportion, header/footer
  for _ = 1, 10 do r.int_byte_str() end            -- page setup texts
  r.int_byte_str()                                   -- tempo name
  local tempo = r.i32()
  if not v500 then r.bool() end                      -- hide tempo
  local song_key = r.i8()
  r.i32()                                            -- octave

  -- 64 MIDI channels (instrument + 6 values + 2 blank)
  local channels = {}
  for i = 1, 64 do
    channels[i] = { instrument = r.i32() }
    r.skip(8)
  end

  local directions = {}
  for _, name in ipairs(SIGNS) do directions[#directions + 1] = { name = name, bar = r.i16(), jump = false } end
  for _, name in ipairs(JUMPS) do directions[#directions + 1] = { name = name, bar = r.i16(), jump = true } end
  r.i32() -- master reverb

  local nmeasures, ntracks = r.i32(), r.i32()
  if nmeasures < 0 or nmeasures > 100000 or ntracks < 0 or ntracks > 1000 then
    error("Corrupt Guitar Pro file (bar/track count).", 0)
  end

  -- measure headers
  local num, den = 4, 4
  local key_count, key_mode = song_key, "Major"
  local nsec = 0
  for i = 1, nmeasures do
    if i > 1 then r.skip(1) end
    local flags = r.u8()
    if flags & 1 ~= 0 then num = r.i8() end
    if flags & 2 ~= 0 then den = r.i8() end
    local m = { index = i, num = num, den = den, qn = num * 4 / den, bars = {} }
    m.repeat_start = flags & 4 ~= 0
    if flags & 8 ~= 0 then
      local raw = r.i8()
      m.repeat_end = true
      m.repeat_count = math.max(2, raw) -- total number of plays
    end
    if flags & 32 ~= 0 then
      local title = utf8_from_cp1252(r.int_byte_str())
      r.skip(4) -- color
      nsec = nsec + 1 -- unnamed sections get letters like in Guitar Pro 6-8: A, B, C ...
      local letter = nsec <= 26 and string.char(64 + nsec) or ("Part " .. nsec)
      m.section = title ~= "" and title or letter
      m.section_letter = letter
    end
    if flags & 64 ~= 0 then
      key_count = r.i8()
      key_mode = (r.i8() == 1) and "Minor" or "Major"
    end
    local mask = 0
    if flags & 16 ~= 0 then mask = r.u8() end   -- alternate endings (bit 0 = ending 1)
    if flags & 3 ~= 0 then r.skip(4) end        -- beam groups
    if flags & 16 == 0 then r.skip(1) end
    r.u8()                                      -- triplet feel
    m.key_count, m.key_mode = key_count, key_mode
    if mask ~= 0 then
      m.alt = {}
      for b = 0, 7 do if mask & (1 << b) ~= 0 then m.alt[b + 1] = true end end
    end
    score.masterbars[i] = m
  end
  for _, d in ipairs(directions) do
    local m = d.bar >= 1 and score.masterbars[d.bar]
    if m then
      m.has_directions = true
      m.targets, m.jumps = m.targets or {}, m.jumps or {}
      if d.jump then m.jumps[#m.jumps + 1] = d.name else m.targets[#m.targets + 1] = d.name end
    end
  end

  -- tracks
  for t = 1, ntracks do
    if t == 1 or v500 then r.skip(1) end
    local flags = r.u8()
    local name = utf8_from_cp1252(r.byte_str(40))
    local nstrings = r.i32()
    local tuning = {}
    for s = 1, 7 do
      local v = r.i32()
      if s <= nstrings then tuning[s] = v end
    end
    r.i32() -- port
    local ch = r.i32() - 1
    r.i32() -- effect channel
    r.i32() -- fret count
    local capo = r.i32()
    local cr, cg, cb = r.u8(), r.u8(), r.u8(); r.skip(1)
    r.i16()                  -- display flags
    r.skip(3)                -- auto accentuation, bank, humanize
    r.skip(4 + 4 + 4 + 12)   -- clef transposes, ?, blank
    r.skip(12)               -- RSE instrument: instrument, unknown, sound bank
    if v500 then r.skip(3) else r.skip(4) end -- effect number
    if not v500 then
      r.skip(4)              -- equalizer (3 knobs + gain)
      r.int_byte_str(); r.int_byte_str() -- RSE effect, category
    end
    local is_drums = (flags & 1) ~= 0 or (ch % 16) == 9
    local instr = channels[ch + 1] and channels[ch + 1].instrument
    score.tracks[t] = {
      index = t, id = tostring(t),
      name = name ~= "" and name or ("Track " .. t),
      instrument = is_drums and "Drums" or (instr and instr >= 0 and ("GM " .. instr) or ""),
      is_drums = is_drums,
      art_out = {},
      staves = { { col = t - 1, tuning = tuning, capo = capo } },
      color = { cr, cg, cb },
      gp_channel = ch >= 0 and (ch % 16) or 0,
      chord_names = {},
      lyrics = (t == lyrics_track) and lyric_lines or {},
    }
  end
  r.skip(v500 and 2 or 1)

  -- measures
  local nvoices = 2
  local id = 0
  local function nid() id = id + 1; return tostring(id) end
  local tempo_seen = {}
  score.tempos[1] = { bar = 1, pos = 0, bpm = tempo, linear = false }
  tempo_seen["1|0.0000"] = score.tempos[1]
  local last_on_string = {} -- [track][voice][string] -> note (ties)
  local chord_id = 0

  local function read_bend()
    r.i8(); r.i32()
    local n = r.i32()
    r.skip(n * 9)
    return n > 0
  end

  local function read_grace()
    local g = {}
    g.fret = r.u8(); g.dyn = r.u8(); r.u8(); g.dur = 1 << (7 - r.u8())
    local fl = r.u8()
    g.dead = fl & 1 ~= 0
    g.on_beat = fl & 2 ~= 0
    return g
  end

  local function read_note_effects(note)
    local f1 = r.u8()
    local f2 = r.u8()
    note.letring = f1 & 8 ~= 0
    if f1 & 1 ~= 0 then note.bend = read_bend() end
    local grace
    if f1 & 16 ~= 0 then grace = read_grace() end
    note.staccato = f2 & 1 ~= 0
    note.palm = f2 & 2 ~= 0
    if f2 & 4 ~= 0 then r.i8() end                     -- tremolo picking
    if f2 & 8 ~= 0 then note.slide = true; r.u8() end  -- slide type
    if f2 & 16 ~= 0 then                               -- harmonic
      note.harmonic = true
      local ht = r.i8()
      if ht == 2 then r.skip(3) elseif ht == 3 then r.skip(1) end
    end
    if f2 & 32 ~= 0 then r.skip(2) end                 -- trill
    return grace
  end

  local function read_mix_table(ctx)
    r.i8()                                -- instrument
    r.skip(12); if v500 then r.skip(3) else r.skip(4) end -- RSE instrument
    if v500 then r.skip(1) end
    local vals = {}
    for k = 1, 6 do vals[k] = r.i8() end -- volume, balance, chorus, reverb, phaser, tremolo
    r.int_byte_str()                      -- tempo name
    local t = r.i32()
    for k = 1, 6 do if vals[k] >= 0 then r.i8() end end
    if t >= 0 then
      r.i8()                              -- tempo transition
      if not v500 then r.bool() end       -- hide tempo
    end
    r.i8()                                -- "all tracks" flags
    r.i8()                                -- wah
    if not v500 then r.int_byte_str(); r.int_byte_str() end -- RSE effect
    if t >= 0 then
      local mb = score.masterbars[ctx.mb]
      local pos = mb.qn > 0 and (ctx.qn / mb.qn) or 0
      if pos >= 1 then pos = 0.999 end
      local key = ctx.mb .. "|" .. string.format("%.4f", pos)
      if tempo_seen[key] then
        tempo_seen[key].bpm = t
      else
        local e = { bar = ctx.mb, pos = pos, bpm = t, linear = false }
        tempo_seen[key] = e
        score.tempos[#score.tempos + 1] = e
      end
    end
  end

  local function read_chord(tr, nstrings)
    local name = ""
    if not r.bool() then -- old format
      name = r.int_byte_str()
      if r.i32() ~= 0 then r.skip(6 * 4) end
    else
      r.skip(1 + 3 + 3 + 4 + 4 + 1)
      name = r.byte_str(22)
      r.skip(3 + 4 + 7 * 4 + 1 + 5 * 3 + 7 + 1 + 7 + 1)
    end
    name = utf8_from_cp1252(name)
    if name:find("%S") then
      chord_id = chord_id + 1
      local cid = "c" .. chord_id
      tr.chord_names[cid] = name
      return cid
    end
  end

  local function read_beat(tr, ti, vi, ctx, list)
    local flags = r.u8()
    local status = 1
    if flags & 64 ~= 0 then status = r.u8() end
    local dv = 1 << (r.i8() + 2)               -- 1 = whole, 4 = quarter
    local qn = 4 / dv
    if flags & 1 ~= 0 then qn = qn * 1.5 end
    if flags & 32 ~= 0 then
      local enters = r.i32()
      local times = TUPLET_TIMES[enters]
      if times then qn = qn * times / enters end
    end
    local beat = { dur = qn, dyn = "F", notes = {} }
    if flags & 2 ~= 0 then beat.chord = read_chord(tr, #tr.staves[1].tuning) end
    if flags & 4 ~= 0 then
      local txt = utf8_from_cp1252(r.int_byte_str())
      if txt ~= "" then beat.free_text = txt end
    end
    if flags & 8 ~= 0 then                     -- beat effects
      local f1, f2 = r.u8(), r.u8()
      if f1 & 32 ~= 0 then r.i8() end          -- slap/tap/pop
      if f2 & 4 ~= 0 then read_bend() end      -- tremolo bar
      if f1 & 64 ~= 0 then r.skip(2) end       -- stroke
      if f2 & 2 ~= 0 then r.i8() end           -- pick stroke
    end
    if flags & 16 ~= 0 then read_mix_table(ctx) end

    -- notes: one bit per string, 7 = highest string
    local sflags = r.u8()
    local graces = {}
    local tuning = tr.staves[1].tuning
    local nstr = #tuning
    for s = 1, 7 do
      if s <= nstr and sflags & (1 << (7 - s)) ~= 0 then
        local nf = r.u8()
        local note = { id = nid(), string = s }
        if nf & 2 ~= 0 then note.accent = 2 end
        note.ghost = nf & 4 ~= 0
        if nf & 64 ~= 0 then note.accent = 1 end
        local ntype = 1
        if nf & 32 ~= 0 then ntype = r.u8() end
        if nf & 16 ~= 0 then note.dyn = dyn_name(r.i8()) end
        local fret = 0
        if nf & 32 ~= 0 then fret = r.i8() end
        if nf & 128 ~= 0 then r.skip(2) end          -- fingering
        if nf & 1 ~= 0 then r.skip(8) end           -- duration percent
        r.u8()                                      -- flags2
        if nf & 8 ~= 0 then
          local g = read_note_effects(note)
          if g then graces[#graces + 1] = { g = g, s = s } end
        end
        local lt = last_on_string[ti][vi]
        if ntype == 2 then
          local prev = lt[s]
          note.tie_dest = true
          if prev then prev.tie_origin = true; fret = prev.fret end
        end
        note.dead = ntype == 3
        note.fret = fret
        note.string = s
        if tr.is_drums then
          note.midi = fret
        elseif tuning[s] then
          note.midi = tuning[s] + fret + (tr.staves[1].capo or 0)
        end
        lt[s] = note
        notes[note.id] = note
        beat.notes[#beat.notes + 1] = note.id
      end
    end
    local bf2 = r.i16()
    if bf2 & 2048 ~= 0 then r.u8() end

    if status == 0 then -- empty beat: takes no time
      beat.dur = 0
      beat.notes = {}
    elseif status == 2 then
      beat.notes = {}
    end

    -- grace notes (GP5 stores them on the note) -> separate grace beat before the main beat
    if #graces > 0 and status == 1 then
      local gb = { dur = 4 / graces[1].g.dur, dyn = dyn_name(graces[1].g.dyn), notes = {},
        grace = graces[1].g.on_beat and "OnBeat" or "BeforeBeat" }
      for _, x in ipairs(graces) do
        local gn = { id = nid(), string = x.s, dead = x.g.dead }
        if tr.is_drums then gn.midi = x.g.fret
        elseif tuning[x.s] then gn.midi = tuning[x.s] + x.g.fret + (tr.staves[1].capo or 0) end
        notes[gn.id] = gn
        gb.notes[#gb.notes + 1] = gn.id
      end
      local gid = nid()
      beats[gid] = gb
      list[#list + 1] = gid
    end

    local bid = nid()
    beats[bid] = beat
    list[#list + 1] = bid
    ctx.qn = ctx.qn + beat.dur
  end

  for t = 1, ntracks do
    last_on_string[t] = {}
    for v = 1, nvoices do last_on_string[t][v] = {} end
  end

  for mi = 1, nmeasures do
    local mb = score.masterbars[mi]
    for t = 1, ntracks do
      local tr = score.tracks[t]
      local bar_id = nid()
      local bar = { voices = {} }
      for v = 1, nvoices do
        local nbeats = r.i32()
        if nbeats < 0 or nbeats > 10000 then error("Corrupt Guitar Pro file (beat count).", 0) end
        local list = {}
        local ctx = { mb = mi, qn = 0 }
        for _ = 1, nbeats do read_beat(tr, t, v, ctx, list) end
        local vid = nid()
        voices[vid] = list
        bar.voices[#bar.voices + 1] = vid
      end
      if r.pos <= #data then r.u8() end -- line break (may be missing at the end)
      bars[bar_id] = bar
      mb.bars[t] = bar_id
    end
  end

  table.sort(score.tempos, function(a, b)
    if a.bar ~= b.bar then return a.bar < b.bar end
    return a.pos < b.pos
  end)
  return score
end

---------------------------------------------------------------------------
-- Guitar Pro 6 (.gpx): BCFZ (compressed) / BCFS (sector file system) -> score.gpif
---------------------------------------------------------------------------

local function bcfz_decompress(data)
  local expected = string.unpack("<i4", data, 5)
  local bytepos, bitpos, cur = 9, 8, 0
  local function bit()
    if bitpos == 8 then
      cur = data:byte(bytepos)
      if not cur then error("Corrupt .gpx file (unexpected end).", 0) end
      bytepos = bytepos + 1
      bitpos = 0
    end
    local b = (cur >> (7 - bitpos)) & 1
    bitpos = bitpos + 1
    return b
  end
  local function bits(n) -- MSB first
    local v = 0
    for i = n - 1, 0, -1 do v = v | (bit() << i) end
    return v
  end
  local function bits_rev(n) -- LSB first
    local v = 0
    for i = 0, n - 1 do v = v | (bit() << i) end
    return v
  end
  local out, len = {}, 0
  while len < expected do
    if bit() == 1 then
      local ws = bits(4)
      local offset = bits_rev(ws)
      local size = bits_rev(ws)
      local src = len - offset
      if offset <= 0 or src < 0 then error("Corrupt .gpx file (bad back reference).", 0) end
      for i = 1, math.min(offset, size) do
        len = len + 1
        out[len] = out[src + i]
      end
    else
      local size = bits_rev(2)
      for _ = 1, size do
        len = len + 1
        out[len] = string.char(bits(8))
      end
    end
  end
  return table.concat(out, "", 1, math.min(len, expected))
end

-- BCFS payload (without the 4-byte header) -> { [name] = data }
local function bcfs_files(data)
  local SECTOR = 0x1000
  local files = {}
  local function int_at(o) return (o + 4 <= #data) and string.unpack("<i4", data, o + 1) or 0 end
  local offset = SECTOR
  while offset + SECTOR <= #data do
    if int_at(offset) == 2 then
      local name = data:sub(offset + 0x04 + 1, offset + 0x04 + 127):match("^[^%z]*")
      local size = int_at(offset + 0x8C)
      local ptr = offset + 0x94
      local parts, k = {}, 0
      while true do
        local sector = int_at(ptr + 4 * k)
        k = k + 1
        if sector == 0 then break end
        offset = sector * SECTOR
        parts[#parts + 1] = data:sub(offset + 1, offset + SECTOR)
      end
      files[name] = table.concat(parts):sub(1, size)
    end
    offset = offset + SECTOR
  end
  return files
end

function F.is_gpx(data)
  local h = data:sub(1, 4)
  return h == "BCFZ" or h == "BCFS"
end

function F.gpx_gpif(data)
  local fs
  if data:sub(1, 4) == "BCFZ" then
    local raw = bcfz_decompress(data)
    if raw:sub(1, 4) ~= "BCFS" then error("Corrupt .gpx file (no BCFS data).", 0) end
    fs = raw:sub(5)
  else
    fs = data:sub(5)
  end
  local files = bcfs_files(fs)
  local xml = files["score.gpif"]
  if not xml then error("No score.gpif inside the .gpx file.", 0) end
  return xml
end

F._bcfz_decompress = bcfz_decompress
return F
