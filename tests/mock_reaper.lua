-- Minimal REAPER API mock: 4/4, 0.5 s per QN (time math simplified).
local M = { tracks = {}, ext = {}, markers = {}, tempo = {}, log = {}, inputs_calls = 0, guid = 0 }
local function newguid() M.guid = M.guid + 1; return string.format("{GUID-%04d}", M.guid) end
reaper = {}
function reaper.GetOS() return "Win64" end
function reaper.GetResourcePath() return M.resource end
function reaper.RecursiveCreateDirectory(p) os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') return 1 end
function reaper.ExecProcess(cmd, t) local ok = os.execute('"' .. cmd .. '"'); return ok and "0\n" or "1\n" end
function reaper.ShowConsoleMsg(s) io.write(s) end
function reaper.GetProjExtState(p, s, k) local v = M.ext[s .. "/" .. k]; return v and 1 or 0, v or "" end
function reaper.SetProjExtState(p, s, k, v)
  if k == "" then
    for key in pairs(M.ext) do if key:sub(1, #s + 1) == s .. "/" then M.ext[key] = nil end end
    return
  end
  M.ext[s .. "/" .. k] = v
end
function reaper.MarkProjectDirty() end
M.gext = M.gext or {}
function reaper.GetExtState(s, k) return M.gext[s .. "/" .. k] or "" end
function reaper.SetExtState(s, k, v, p) M.gext[s .. "/" .. k] = v end
function reaper.DeleteExtState(s, k) M.gext[s .. "/" .. k] = nil end
function reaper.CountTracks() return #M.tracks end
function reaper.GetTrack(p, i) return M.tracks[i + 1] end
function reaper.GetTrackGUID(tr) return tr.guid end
function reaper.GetSetMediaTrackInfo_String(tr, k, v, set) if set then tr[k] = v end return true, tr[k] or "" end
function reaper.InsertTrackAtIndex(i) table.insert(M.tracks, i + 1, { guid = newguid(), items = {} }) end
function reaper.SetMediaTrackInfo_Value(tr, k, v) tr[k] = v end
function reaper.ColorToNative(r, g, b) return r | (g << 8) | (b << 16) end
function reaper.TimeMap_GetMeasureInfo(p, m) return m * 2.0, m * 4.0, m * 4.0 + 4, 4, 4, 120 end
function reaper.CountTempoTimeSigMarkers() return #M.tempo end
function reaper.GetTempoTimeSigMarker(p, i) local t = M.tempo[i + 1]; return true, t.time end
function reaper.DeleteTempoTimeSigMarker(p, i) table.remove(M.tempo, i + 1) end
function reaper.SetTempoTimeSigMarker(p, idx, tpos, meas, beat, bpm, num, den, lin)
  assert(idx == -1 and tpos == -1)
  table.insert(M.tempo, { time = meas * 2.0 + beat * 0.5, meas = meas, beat = beat, bpm = bpm, num = num, den = den, lin = lin })
  return true
end
function reaper.UpdateTimeline() end
function reaper.EnumProjectMarkers3(p, i)
  local m = M.markers[i + 1]; if not m then return 0 end
  return i + 1, m.isrgn, m.pos, m.rend, m.name, m.idx, m.color
end
function reaper.DeleteProjectMarker(p, idx, isrgn)
  for i, m in ipairs(M.markers) do if m.idx == idx and m.isrgn == isrgn then table.remove(M.markers, i) return true end end
  return false
end
function reaper.TimeMap2_QNToTime(p, qn) return qn * 0.5 end
function reaper.AddProjectMarker2(p, isrgn, pos, rend, name, want, color)
  local used = {}; for _, m in ipairs(M.markers) do if m.isrgn == isrgn then used[m.idx] = true end end
  local idx = 1; while used[idx] do idx = idx + 1 end
  table.insert(M.markers, { isrgn = isrgn, pos = pos, rend = rend, name = name, idx = idx, color = color })
  return idx
end
function reaper.CountTrackMediaItems(tr) return #tr.items end
function reaper.GetTrackMediaItem(tr, i) return tr.items[i + 1] end
function reaper.GetSetMediaItemInfo_String(it, k, v, set) if set then it.ext[k] = v end return true, it.ext[k] or "" end
function reaper.GetMediaItemInfo_Value(it, k) return it[k] or 0 end
function reaper.GetMediaItemInfo_Value(it, k) return it[k] or 0 end
function reaper.CreateNewMIDIItemInProj(tr, s, e, qn)
  assert(qn == true)
  local it = { track = tr, s = s, e = e, ext = {}, take = { notes = {}, name = "" } }
  it.take.item = it
  table.insert(tr.items, it); return it
end
function reaper.GetActiveTake(it) return it.take end
function reaper.GetSetMediaItemTakeInfo_String(tk, k, v, set) if set then tk[k] = v end return true, tk[k] or "" end
function reaper.MIDI_GetPPQPosFromProjQN(tk, qn) return (qn - tk.item.s) * 960 end
function reaper.MIDI_InsertNote(tk, sel, mute, s, e, c, p, v, ns)
  assert(s >= 0 and e > s and c >= 0 and c <= 15 and p >= 0 and p <= 127 and v >= 1 and v <= 127, "bad note")
  table.insert(tk.notes, { s, e, c, p, v }) return true
end
function reaper.MIDI_Sort() end
function reaper.DeleteTrackMediaItem(tr, it) for i, x in ipairs(tr.items) do if x == it then table.remove(tr.items, i) return true end end end
function reaper.Undo_BeginBlock2() end
function reaper.Undo_EndBlock2(p, d) table.insert(M.log, "undo:" .. d) end
function reaper.PreventUIRefresh() end
function reaper.UpdateArrange() end
function reaper.GetCursorPositionEx() return 0 end
function reaper.TimeMap2_timeToBeats(p, t) return 0, math.floor(t / 2), 4, t * 2, 4 end
function reaper.GetUserInputs(title, n, caps, vals)
  M.inputs_calls = M.inputs_calls + 1
  M.last_inputs = { title = title, n = n, caps = caps, vals = vals }
  if M.inputs_override then vals = M.inputs_override(vals) end
  return true, vals
end
function reaper.MB(m, t, ty) table.insert(M.log, "MB:" .. m); return M.mb_answer or 6 end
function reaper.GetUserFileNameForRead() return true, M.gpfile end
function reaper.get_action_context() return false, "", 0, 4242 end
function reaper.SetToggleCommandState(s, c, v) M.toggle = v end
function reaper.RefreshToolbar2() end
function reaper.time_precise() M.clock = (M.clock or 0) + 1; return M.clock end
function reaper.EnumProjects(i) if i == -1 or i == 0 then return 0, M.projfn or "" end return nil end
function reaper.NamedCommandLookup(n) return M.named and M.named[n] or 0 end
function reaper.Main_OnCommand(c, f)
  M.cmd_log = (M.cmd_log or "") .. c .. ";"
  if M.on_command then M.on_command(c) end
end
function reaper.AddMediaItemToTrack(tr)
  local it = { track = tr, ext = {}, empty = true }
  table.insert(tr.items, it); return it
end
function reaper.SetMediaItemInfo_Value(it, k, v) it[k] = v end
function reaper.MIDI_InsertTextSysexEvt(tk, sel, mute, ppq, typ, msg)
  tk.texts = tk.texts or {}; table.insert(tk.texts, { ppq, typ, msg }) return true
end
function reaper.GetPlayStateEx() return 0 end
function reaper.defer(f) M.deferred = f end
function reaper.atexit(f) M.atexit = f end
return M
