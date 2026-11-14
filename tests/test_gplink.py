"""GP-Link tests: Lua engine + REAPER scripts against a mocked REAPER API.

    pip install lupa pyguitarpro
    python tests/test_gplink.py

Uses the generated demo song (tools/make_demo_gp.py). Runs on Windows (the scripts unpack the
.gp with the Windows tar/PowerShell tools, like inside REAPER).
"""
import os
import shutil
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET

import lupa.lua54 as L

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GL = os.path.join(ROOT, "scripts").replace("\\", "/")
TESTS = os.path.join(ROOT, "tests").replace("\\", "/")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import make_demo_gp  # noqa: E402
import make_demo_gp5  # noqa: E402
import make_demo_gpx  # noqa: E402
import guitarpro  # noqa: E402  (reference parser for .gp5)

WORK = tempfile.mkdtemp(prefix="gplink_test_")
DEMO = make_demo_gp.main(os.path.join(WORK, "demo.gp"))
DEMO5 = make_demo_gp5.main(os.path.join(WORK, "gp5"))
DEMOX = make_demo_gpx.main(DEMO, os.path.join(WORK, "demo.gpx"))
PASSED = []


def test(fn):
    fn()
    PASSED.append(fn.__name__)
    print("ok  ", fn.__name__)
    return fn


def vals(t):
    return list(t.values()) if t else []


def new_lua():
    return L.LuaRuntime(unpack_returned_tuples=True)


def load_core(lua):
    return lua.eval("function(p) return dofile(p) end")(GL + "/gplink_core.lua")


def mock_reaper(sub):
    """fresh Lua state + mocked REAPER, working dir with a copy of the demo song"""
    lua = new_lua()
    M = lua.eval("function(p) return dofile(p) end")(TESTS + "/mock_reaper.lua")
    work = os.path.join(WORK, sub)
    os.makedirs(os.path.join(work, "Songs"), exist_ok=True)
    os.makedirs(os.path.join(work, "Projekt"), exist_ok=True)
    gp = os.path.join(work, "Songs", "demo.gp")
    shutil.copy(DEMO, gp)
    M.resource = work
    M.gpfile = gp
    run = lua.eval("function(p) local f = assert(loadfile(p)); return f() end")
    return lua, M, run, work, gp


def undo_count(M):
    return len([x for x in vals(M.log) if x.startswith("undo:")])


def tracks_by_name(M):
    return {t["P_NAME"]: t for t in vals(M.tracks)}


# ---------------------------------------------------------------------------
@test
def core_notes_match_reference():
    """Lua parser note count per track == independent Python count of the GPIF"""
    lua = new_lua()
    core = load_core(lua)
    xml = zipfile.ZipFile(DEMO).read("Content/score.gpif").decode("utf-8")
    tl = core.build(core.parse_gpif(xml), lua.table())
    lua_counts = {t.name: len(vals(t.notes)) for t in vals(tl.tracks)}

    r = ET.fromstring(xml)
    by_id = lambda s: {e.get("id"): e for e in r.find(s)}
    B, V, Be = by_id("Bars"), by_id("Voices"), by_id("Beats")
    names = [t.find("Name").text for t in r.find("Tracks")]
    mbs = list(r.find("MasterBars"))
    order = []  # unrolled master bars: chorus 9-12 repeated
    for i in range(1, len(mbs) + 1):
        order.append(i)
        if i == 12:
            order += [9, 10, 11, 12]
    ref = [0] * len(names)
    for i in order:
        for col, bid in enumerate(mbs[i - 1].find("Bars").text.split()):
            for v in B[bid].find("Voices").text.split():
                if v == "-1":
                    continue
                for bt in V[v].find("Beats").text.split():
                    ns = Be[bt].find("Notes")
                    ref[col] += len(ns.text.split()) if ns is not None else 0
    assert lua_counts == dict(zip(names, ref)), (lua_counts, ref)
    assert len(vals(tl.bars)) == 28 and tl.length == 110.0, (len(vals(tl.bars)), tl.length)


@test
def core_structure():
    lua = new_lua()
    core = load_core(lua)
    xml = zipfile.ZipFile(DEMO).read("Content/score.gpif").decode("utf-8")
    score = core.parse_gpif(xml)
    tl = core.build(score, lua.table())
    secs = [s.name for s in vals(tl.sections)]
    assert secs == ["Intro", "Verse 1", "Chorus 1", "Chorus 2", "Verse 2", "Chorus 3", "Break", "Outro"], secs
    tempo = [(t.bpm, t.num, t.den) for t in vals(tl.tempo)]
    assert (112, 4, 4) in tempo and (120, 2, 4) in tempo, tempo
    texts = [t.text for t in vals(tl.texts)]
    for want in ("Key: E minor", "Segno", "Riff!", "Key: B minor", "D.S. al Coda"):
        assert want in texts, (want, texts)
    chords = [c.name for c in vals(tl.chords)]
    assert chords[:4] == ["E5", "C5", "D5", "B5"] and tl.chords_source == "Rhythm Guitar", chords
    vox = [t for t in vals(tl.tracks) if t.name == "Vocals"][0]
    lyr = [l.text for l in vals(vox.lyrics)]
    assert lyr[:3] == ["Lights", "a-", "cross"] and vox.lyrics[1].qn == 16.0, lyr
    assert list(core.lyric_tokens("Hal-le-lu-jah, so+far").values()) == ["Hal-", "le-", "lu-", "jah,", "so far"]
    assert core.key_name(1, "Minor") == "E minor" and core.key_name(-3, "Major") == "Eb major"

    tl2 = core.build(score, lua.eval("{ countin = 2, number_sections = false }"))
    assert tl2.length == tl.length + 8
    assert [s.name for s in vals(tl2.sections)][:3] == ["Count-in", "Intro", "Verse"]
    assert vals(tl2.chords)[0].qn == 8.0


@test
def core_repeats():
    lua = new_lua()
    core = load_core(lua)
    mk = lua.eval("""function()
      local mb = {}
      for i=1,5 do mb[i] = {index=i, num=4, den=4, qn=4, bars={}} end
      mb[2].repeat_start = true
      mb[3].alt = {[1]=true}; mb[3].repeat_end = true; mb[3].repeat_count = 2
      mb[4].alt = {[2]=true}
      return {masterbars=mb, warnings={}}
    end""")
    assert vals(core.unroll(mk())) == [1, 2, 3, 2, 4, 5]
    mk2 = lua.eval("""function()
      local mb = {}
      for i=1,4 do mb[i] = {index=i, num=4, den=4, qn=4, bars={}} end
      mb[1].repeat_start = true; mb[2].repeat_end = true; mb[2].repeat_count = 3
      mb[3].repeat_start = true; mb[4].repeat_end = true; mb[4].repeat_count = 2
      return {masterbars=mb, warnings={}}
    end""")
    assert vals(core.unroll(mk2())) == [1, 2, 1, 2, 1, 2, 3, 4, 3, 4]


def gp5_reference(path):
    """independent view of a .gp5 file via PyGuitarPro: notes, bars, tempos"""
    song = guitarpro.parse(path)
    notes = []
    tempos = {(1, 0.0): song.tempo}
    for ti, tr in enumerate(song.tracks):
        tun = [s.value for s in tr.strings]
        for mi, m in enumerate(tr.measures):
            mlen = m.header.length
            for vi, v in enumerate(m.voices):
                for b in v.beats:
                    off = (b.start - m.start) / 960
                    mt = b.effect.mixTableChange
                    if mt is not None and mt.tempo is not None:
                        tempos[(mi + 1, round((b.start - m.start) / mlen, 4))] = mt.tempo.value
                    if b.status != guitarpro.BeatStatus.normal:
                        continue
                    for n in b.notes:
                        pitch = n.value if tr.isPercussionTrack else n.value + tun[n.string - 1] + tr.offset
                        notes.append((ti + 1, mi + 1, vi + 1, round(off, 4), pitch))
    bars, nsec = [], 0
    for h in song.measureHeaders:
        sec = None
        if h.marker:
            nsec += 1
            sec = h.marker.title or (chr(64 + nsec) if nsec <= 26 else "Part %d" % nsec)
        bars.append((h.timeSignature.numerator, h.timeSignature.denominator.value,
                     sec, h.isRepeatOpen, h.repeatClose))
    return song, sorted(notes), tempos, bars


def gp5_lua(lua, core, F, path):
    data = open(path, "rb").read()
    score = F.parse_gp5(data)
    notes = []
    for ti, tr in enumerate(vals(score.tracks)):
        for mi, mb in enumerate(vals(score.masterbars)):
            bar = score._bars[mb.bars[ti + 1]]
            for vi, vid in enumerate(vals(bar.voices)):
                pos = 0.0
                for bid in vals(score._voices[vid]):
                    bt = score._beats[bid]
                    if bt.grace:
                        continue
                    for nid in vals(bt.notes):
                        notes.append((ti + 1, mi + 1, vi + 1, round(pos, 4), score._notes[nid].midi))
                    pos += bt.dur
    tempos = {(t.bar, round(t.pos, 4)): t.bpm for t in vals(score.tempos)}
    bars = []
    for mb in vals(score.masterbars):
        bars.append((mb.num, mb.den, mb.section, bool(mb.repeat_start),
                     (mb.repeat_count - 1) if mb.repeat_end else -1))
    return score, sorted(notes), tempos, bars


@test
def gp5_matches_reference():
    """GP5 binary parser == PyGuitarPro, note by note"""
    lua = new_lua()
    core = load_core(lua)
    F = lua.eval("function(p) return dofile(p) end")(GL + "/gplink_formats.lua")
    _, rn, rt, rb = gp5_reference(DEMO5)
    score, ln, lt, lb = gp5_lua(lua, core, F, DEMO5)
    assert len(rn) > 200 and ln == rn, (len(ln), len(rn), [x for x in rn if x not in ln][:5], [x for x in ln if x not in rn][:5])
    assert lt == rt, (lt, rt)
    assert lb == rb, (lb, rb)
    # GP3/GP4 files: clear message instead of garbage
    old = make_demo_gp5.main(os.path.join(WORK, "gp4"), version=(4, 0, 6), ext="gp4")
    data = open(old, "rb").read()
    assert F.is_gp_binary(data)
    ok, err = lua.eval("function(f, d) return pcall(f, d) end")(F.parse_gp5, data)
    assert not ok and "older Guitar Pro" in err and "v4.06" in err, err


@test
def gp5_structure():
    lua = new_lua()
    core = load_core(lua)
    F = lua.eval("function(p) return dofile(p) end")(GL + "/gplink_formats.lua")
    score = F.parse_gp5(open(DEMO5, "rb").read())
    tl = core.build(score, lua.table())
    assert [b.mb for b in vals(tl.bars)] == [1, 2, 3, 4, 3, 5, 6, 7, 8], [b.mb for b in vals(tl.bars)]
    assert [s.name for s in vals(tl.sections)] == ["Intro", "Verse 1", "Verse 2", "Chorus", "Outro"]
    tempo = [(t.bpm, t.num, t.den) for t in vals(tl.tempo)]
    assert tempo[0] == (100, 4, 4) and (120, 3, 4) in tempo, tempo
    texts = [t.text for t in vals(tl.texts)]
    for want in ("Riff!", "Key: E minor", "Key: B minor", "Segno", "D.S. al Coda", "Coda"):
        assert want in texts, (want, texts)
    assert [c.name for c in vals(tl.chords)] == ["Em", "G"], [c.name for c in vals(tl.chords)]
    trk = {t.name: t for t in vals(tl.tracks)}
    assert list(trk) == ["Rhythm Gtr", "Bass", "Drums", "Vocals"]
    gtr = vals(trk["Rhythm Gtr"].notes)
    assert min(n.p for n in gtr) == 42                  # low E + capo 2
    first = sorted(gtr, key=lambda n: (n.s, n.p))[0]
    assert first.s == 0 and first.e == 1.0, (first.s, first.e)
    tied = [n for n in gtr if n.s == 4.0]               # bar 2: tie extends the first beat
    assert tied and all(n.e == 6.0 for n in tied), [(n.s, n.e) for n in tied]
    assert any(abs(n.e - n.s - 0.125) < 1e-6 for n in gtr)   # grace note
    assert {n.p for n in vals(trk["Drums"].notes)} == {36, 38, 42} and vals(trk["Drums"].notes)[0].c == 9
    bass = vals(trk["Bass"].notes)
    assert max(n.v for n in bass) > min(n.v for n in bass)  # accents / ghost / dynamics
    lyr = [l.text for l in vals(trk["Vocals"].lyrics)]
    assert lyr[:3] == ["Here", "we", "go"] and vals(trk["Vocals"].lyrics)[0].qn == 8.0, lyr


@test
def gpx_container():
    """Guitar Pro 6: BCFZ decompression + BCFS file system -> the same score.gpif"""
    lua = new_lua()
    F = lua.eval("function(p) return dofile(p) end")(GL + "/gplink_formats.lua")
    gpif = zipfile.ZipFile(DEMO).read("Content/score.gpif")
    for compressed in (True, False):
        path = make_demo_gpx.main(DEMO, os.path.join(WORK, "c.gpx" if compressed else "u.gpx"), compressed)
        data = open(path, "rb").read()
        assert F.is_gpx(data) and not F.is_gp_binary(data)
        assert len(data) < len(gpif) or not compressed     # really compressed
        n = lua.eval("function(F, d, want) local x = F.gpx_gpif(d); return #x, x == want end")(F, data, gpif)
        assert n == (len(gpif), True), (compressed, n, len(gpif))


GP6_GPIF = """<?xml version="1.0" encoding="utf-8"?>
<GPIF><GPVersion>6</GPVersion>
<MasterTrack><Tracks>0 1 2 3</Tracks><Automations><Automation><Type>Tempo</Type><Linear>false</Linear>
<Bar>0</Bar><Position>0</Position><Value>90 2</Value></Automation></Automations></MasterTrack>
<Tracks>
<Track id="0"><Name>Guitar</Name><Instrument ref="e-gtr6" /><GeneralMidi table="Instrument"><Program>30</Program>
<PrimaryChannel>2</PrimaryChannel></GeneralMidi><Properties><Property name="Tuning"><Pitches>40 45 50 55 59 64</Pitches>
</Property><Property name="CapoFret"><Fret>2</Fret></Property></Properties></Track>
<Track id="1"><Name>Drums</Name><Instrument ref="drmkt" /><GeneralMidi table="Instrument">
<PrimaryChannel>9</PrimaryChannel></GeneralMidi></Track>
<Track id="2"><Name>Pad</Name><Instrument ref="snt-pad-gs" /><GeneralMidi table="Instrument">
<PrimaryChannel>4</PrimaryChannel></GeneralMidi></Track>
<Track id="3"><Name>Bass</Name><Instrument ref="e-bass4" /><Properties><Property name="Tuning">
<Pitches>28 33 38 43</Pitches></Property></Properties></Track>
</Tracks>
<MasterBars><MasterBar><Time>4/4</Time><Section><Letter>
A
</Letter><Text>
</Text></Section><Bars>0 1 2 3 4</Bars></MasterBar></MasterBars>
<Bars>
<Bar id="0"><Voices>0 -1 -1 -1</Voices></Bar><Bar id="1"><Voices>1 -1 -1 -1</Voices></Bar>
<Bar id="2"><Voices>2 -1 -1 -1</Voices></Bar><Bar id="3"><Voices>-1 -1 -1 -1</Voices></Bar>
<Bar id="4"><Voices>3 -1 -1 -1</Voices></Bar>
</Bars>
<Voices><Voice id="0"><Beats>0</Beats></Voice><Voice id="1"><Beats>1</Beats></Voice>
<Voice id="2"><Beats>2</Beats></Voice><Voice id="3"><Beats>3</Beats></Voice></Voices>
<Beats><Beat id="0"><Rhythm ref="0" /><Notes>0</Notes></Beat><Beat id="1"><Rhythm ref="0" /><Notes>1 2</Notes></Beat>
<Beat id="2"><Rhythm ref="0" /><Notes>3</Notes></Beat><Beat id="3"><Rhythm ref="0" /><Notes>4</Notes></Beat></Beats>
<Notes>
<Note id="0"><Properties><Property name="Fret"><Fret>3</Fret></Property><Property name="String"><String>0</String></Property></Properties></Note>
<Note id="1"><Properties><Property name="Element"><Element>1</Element></Property><Property name="Variation"><Variation>0</Variation></Property></Properties></Note>
<Note id="2"><Properties><Property name="Element"><Element>10</Element></Property><Property name="Variation"><Variation>2</Variation></Property></Properties></Note>
<Note id="3"><Properties><Property name="Tone"><Step>7</Step></Property><Property name="Octave"><Number>4</Number></Property></Properties></Note>
<Note id="4"><Properties><Property name="Fret"><Fret>2</Fret></Property><Property name="String"><String>1</String></Property></Properties></Note>
</Notes>
<Rhythms><Rhythm id="0"><NoteValue>Quarter</NoteValue></Rhythm></Rhythms>
</GPIF>"""


@test
def gp6_score():
    """Guitar Pro 6 gpif: tuning in the track, drum elements, keyboard notes, two-staff tracks"""
    lua = new_lua()
    core = load_core(lua)
    score = core.parse_gpif(GP6_GPIF)
    tl = core.build(score, lua.table())
    got = {t.name: sorted(n.p for n in vals(t.notes)) for t in vals(tl.tracks)}
    assert got == {"Guitar": [45], "Drums": [38, 46], "Pad": [55], "Bass": [35]}, got
    trs = vals(score.tracks)
    assert [t.is_drums for t in trs] == [False, True, False, False]
    assert [len(vals(t.staves)) for t in trs] == [1, 1, 2, 1]
    assert trs[0].gp_channel == 2
    assert [s.name for s in vals(tl.sections)] == ["A"]
    assert [t.bpm for t in vals(tl.tempo)] == [90]


def import_file(sub, src, ext):
    """import a GP file of another format through the import action (text dialog), then re-sync"""
    lua, M, run, work, _ = mock_reaper(sub)
    gp = os.path.join(work, "Songs", "demo." + ext)
    shutil.copy(src, gp)
    M.gpfile = gp
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    tr = tracks_by_name(M)
    n_markers, n_tracks = len(vals(M.markers)), len(vals(M.tracks))
    run(GL + "/GP-Link - Sync now.lua")
    assert len(vals(M.markers)) == n_markers and len(vals(M.tracks)) == n_tracks
    assert not any(x.startswith("MB:") for x in vals(M.log)), [x for x in vals(M.log) if x.startswith("MB:")]
    return M, tr


@test
def import_gp5_and_gpx():
    M, tr = import_file("imp_gp5", DEMO5, "gp5")
    assert list(tr) == ["Chords", "Rhythm Gtr", "Bass", "Drums", "Vocals"], list(tr)
    assert all(len(vals(t["items"])) == 1 for n, t in tr.items() if n != "Chords")
    assert len(vals(tr["Chords"]["items"])) == 2
    regions = [m.name for m in vals(M.markers) if m.isrgn]
    assert regions == ["Intro", "Verse 1", "Verse 2", "Chorus", "Outro"], regions

    M, tr = import_file("imp_gpx", DEMOX, "gpx")
    assert list(tr) == ["Chords", "Drums", "Bass", "Rhythm Guitar", "Vocals", "Synth Pad"], list(tr)

    # older GP / unsupported files: clear message, nothing imported
    lua, M, run, work, _ = mock_reaper("imp_old")
    old = make_demo_gp5.main(os.path.join(work, "Songs"), version=(4, 0, 6), ext="gp4")
    M.gext["GPLINK_DROP/file"] = old
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    assert any("Only Guitar Pro files (.gp, .gpx, .gp5)" in x for x in vals(M.log)), vals(M.log)
    renamed = os.path.join(work, "Songs", "renamed.gp5")
    shutil.copy(old, renamed)
    M.gext["GPLINK_DROP/file"] = renamed
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    assert any("older Guitar Pro" in x for x in vals(M.log)), vals(M.log)
    assert len(vals(M.tracks)) == 0


@test
def import_with_text_dialog_and_resync():
    """without the extension: GetUserInputs fallback, re-sync must not duplicate anything"""
    lua, M, run, work, gp = mock_reaper("plain")
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    tr = tracks_by_name(M)
    assert list(tr) == ["Chords", "Drums", "Bass", "Rhythm Guitar", "Vocals", "Synth Pad"], list(tr)
    assert len(vals(tr["Drums"]["items"])) == 1
    n_markers, n_tracks = len(vals(M.markers)), len(vals(M.tracks))
    run(GL + "/GP-Link - Sync now.lua")
    assert len(vals(M.markers)) == n_markers and len(vals(M.tracks)) == n_tracks
    assert all(len(vals(t["items"])) == (1 if n != "Chords" else len(vals(t["items"]))) for n, t in tracks_by_name(M).items())

    # own region survives, locked item is not touched
    M.markers[len(vals(M.markers)) + 1] = lua.table(isrgn=True, pos=999, rend=1000, name="My own region", idx=50, color=0)
    item = vals(tracks_by_name(M)["Vocals"]["items"])[0]
    item["C_LOCK"] = 1
    run(GL + "/GP-Link - Sync now.lua")
    assert any(m.name == "My own region" for m in vals(M.markers))
    items = vals(tracks_by_name(M)["Vocals"]["items"])
    assert len(items) == 1 and items[0]["C_LOCK"] == 1


def native_dialog(M, lua, answer):
    """simulates the extension: the import dialog action answers via GPLINK_DLG/result"""
    M.named = lua.table(_GPLINK_IMPORT_DIALOG=777)
    seen = {}

    def on_command(cmd):
        if cmd != 777:
            return
        spec = M.gext["GPLINK_DLG/spec"]
        seen["spec"] = spec
        res = answer(spec)
        if res is not None:
            M.gext["GPLINK_DLG/result"] = res
    M.on_command = on_command
    return seen


def answer_from_spec(spec, anchor=3, countin=1, opt=None, untick=()):
    out = ["ok\t1", f"anchor\t{anchor}", f"countin\t{countin}"]
    for line in spec.split("\n"):
        f = line.split("\t")
        if f[0] == "opt":
            out.append(f"opt\t{f[1]}\t{(opt or {}).get(f[1], f[3])}")
        if f[0] == "track":
            out.append(f"track\t{f[1]}\t{'0' if f[1] in untick else f[4]}\t{f[5]}")
    return "\n".join(out)


@test
def import_with_native_dialog():
    lua, M, run, work, gp = mock_reaper("native")  # anchor is stored 0-based (dialog bar 3 -> "2")
    M.projfn = os.path.join(work, "Projekt", "song.rpp")
    seen = native_dialog(M, lua, lambda s: answer_from_spec(s, opt={"section_markers": "1"}, untick=("Synth Pad",)))
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    assert seen["spec"].startswith("title\tGP-Link - demo.gp")
    tr = tracks_by_name(M)
    assert "Synth Pad" not in tr and "Chords" in tr, list(tr)
    assert M.ext["GPLINK/countin"] == "1" and M.ext["GPLINK/anchor"] == "2", (M.ext["GPLINK/countin"], M.ext["GPLINK/anchor"])
    assert M.ext["GPLINK/file_rel"] == "..\\Songs\\demo.gp", M.ext["GPLINK/file_rel"]
    chords = [i.ext["P_NOTES"] for i in vals(tr["Chords"]["items"])]
    assert chords[:3] == ["E5", "C5", "D5"], chords
    texts = vals(vals(tr["Vocals"]["items"])[0].take.texts)
    assert [t[3] for t in texts][:2] == ["Lights", "a-"] and all(t[2] == 5 for t in texts)  # {ppq, type, text}, 5 = lyric
    regions = [m.name for m in vals(M.markers) if m.isrgn]
    markers = [m.name for m in vals(M.markers) if not m.isrgn]
    assert regions[:3] == ["Count-in", "Intro", "Verse 1"], regions
    assert "Segno" in markers and "Chorus 2" in markers and "Key: B minor" in markers, markers

    # structure only: MIDI untouched
    before = {n: len(vals(t["items"])) for n, t in tracks_by_name(M).items()}
    seen = native_dialog(M, lua, lambda s: answer_from_spec(s, anchor=3))
    run(GL + "/GP-Link - Import structure only.lua")
    offered = {l.split("\t")[1]: l.split("\t")[3] for l in seen["spec"].split("\n") if l.startswith("opt")}
    assert offered["midi"] == "0" and offered["lyrics"] == "0" and offered["regions"] == "1", offered
    assert before == {n: len(vals(t["items"])) for n, t in tracks_by_name(M).items()}

    # cancel -> nothing happens
    u = undo_count(M)
    native_dialog(M, lua, lambda s: None)
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    assert undo_count(M) == u

    # band member with another drive letter: project + songs moved together
    moved = os.path.join(WORK, "native_moved")
    shutil.copytree(work, moved)
    M.projfn = os.path.join(moved, "Projekt", "song.rpp")
    R = lua.eval("function(p) return dofile(p) end")(GL + "/gplink_reaper.lua")
    link = R.load_link(0)
    assert os.path.normcase(link.file) == os.path.normcase(os.path.join(moved, "Songs", "demo.gp")), link.file


@test
def drop_and_autosync():
    """what the extension does on a drop, then the auto-sync helper"""
    lua, M, run, work, gp = mock_reaper("drop")
    M.gext["GPLINK_DROP/file"] = gp
    M.gext["GPLINK_DROP/pos"] = "16.0"        # mock: 2 s per measure -> bar 9
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    assert M.ext["GPLINK/anchor"] == "8", M.ext["GPLINK/anchor"]
    assert M.gext["GPLINK_DROP/file"] is None
    u = undo_count(M)
    run(GL + "/gplink_autosync_once.lua")
    assert undo_count(M) == u                  # unchanged file -> no sync
    with open(gp, "ab") as f:
        f.write(b"\0")                         # "Guitar Pro saved"
    run(GL + "/gplink_autosync_once.lua")
    assert undo_count(M) == u + 1
    run(GL + "/gplink_autosync_once.lua")
    assert undo_count(M) == u + 1


@test
def moved_items_follow_on_yes():
    """user drags GP items onto a VSTi track: sync asks; No = back, Yes = remap (also for locked items)"""
    lua, M, run, work, gp = mock_reaper("moved")
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    move = lua.eval("""function(M, from, to)
        local src, dst
        for _, t in ipairs(M.tracks) do
          if t.P_NAME == from then src = t end
          if t.P_NAME == to then dst = t end
        end
        if not dst then
          reaper.InsertTrackAtIndex(#M.tracks, true)
          dst = M.tracks[#M.tracks]; dst.P_NAME = to
        end
        local it = table.remove(src.items, 1)
        dst.items[#dst.items + 1] = it
        return it
    end""")
    count = lambda n: len(vals(tracks_by_name(M)[n]["items"]))

    # No -> item goes back to the linked track, mapping unchanged
    move(M, "Bass", "Bass VSTi")
    M.mb_answer = 7
    run(GL + "/GP-Link - Sync now.lua")
    assert any("moved to another track" in x and "Bass  ->  Bass VSTi" in x for x in vals(M.log))
    assert count("Bass") == 1 and count("Bass VSTi") == 0

    # Yes -> two tracks remapped with one question, the old tracks stay empty from now on
    move(M, "Bass", "Bass VSTi")
    move(M, "Drums", "Drums SD3")
    M.log = lua.table()
    M.mb_answer = 6
    run(GL + "/GP-Link - Sync now.lua")
    asked = [x for x in vals(M.log) if x.startswith("MB:")]
    assert len(asked) == 1 and "Drums  ->  Drums SD3" in asked[0] and "Bass  ->  Bass VSTi" in asked[0]
    assert count("Bass") == 0 and count("Bass VSTi") == 1 and count("Drums") == 0 and count("Drums SD3") == 1
    M.log = lua.table()
    run(GL + "/GP-Link - Sync now.lua")                    # no further question
    assert not any(x.startswith("MB:") for x in vals(M.log))
    assert count("Bass VSTi") == 1 and count("Bass") == 0

    # locked item moved + Yes -> stays frozen there, no duplicate on the old track
    it = move(M, "Vocals", "Vocals Synth")
    it["C_LOCK"] = 1
    run(GL + "/GP-Link - Sync now.lua")
    assert count("Vocals") == 0 and count("Vocals Synth") == 1
    assert vals(tracks_by_name(M)["Vocals Synth"]["items"])[0]["C_LOCK"] == 1

    # import dialog preselects the track the items were moved to; no question after the dialog
    move(M, "Rhythm Guitar", "Guitar VSTi")
    seen = native_dialog(M, lua, lambda spec: answer_from_spec(spec))
    M.log = lua.table()
    M.mb_answer = 7                                         # "No" = keep file, choose parts again
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    spec = seen["spec"].split(chr(10))
    target = [l.split(chr(9)) for l in spec if l.startswith("track" + chr(9))]
    idx = {l.split(chr(9))[1]: l for l in spec if l.startswith("target" + chr(9))}
    rg = [t for t in target if t[2] == "Rhythm Guitar"][0]
    assert "Guitar VSTi" in idx[rg[5]], (rg, idx)
    assert not any("moved to another track" in x for x in vals(M.log))
    assert count("Rhythm Guitar") == 0 and count("Guitar VSTi") == 1


@test
def autosync_waits_while_busy():
    lua, M, run, work, gp = mock_reaper("busy")
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    u = undo_count(M)
    with open(gp, "ab") as f:
        f.write(bytes(1))
    M.gext["GPLINK_EXT/busy"] = "1"                         # another sync waits for an answer
    run(GL + "/gplink_autosync_once.lua")
    assert undo_count(M) == u
    M.gext["GPLINK_EXT/busy"] = ""
    run(GL + "/gplink_autosync_once.lua")
    assert undo_count(M) == u + 1
    assert M.gext["GPLINK_EXT/busy"] == ""                 # flag cleared after the sync


@test
def unlink():
    lua, M, run, work, gp = mock_reaper("unlink")
    R = lua.eval("function(p) return dofile(p) end")(GL + "/gplink_reaper.lua")
    run(GL + "/GP-Link - Unlink.lua")              # not linked -> message only
    assert any("not linked" in x for x in vals(M.log))
    native_dialog(M, lua, lambda spec: answer_from_spec(spec))
    run(GL + "/GP-Link - Import Guitar Pro file.lua")
    n_tracks = len(vals(M.tracks))
    assert R.load_link(0) is not None
    M.mb_answer = 7                                 # "No" -> stays linked
    run(GL + "/GP-Link - Unlink.lua")
    assert R.load_link(0) is not None
    M.mb_answer = 6
    run(GL + "/GP-Link - Unlink.lua")
    assert R.load_link(0) is None
    assert len(vals(M.tracks)) == n_tracks          # tracks are kept


print(f"\n{len(PASSED)} tests passed")
shutil.rmtree(WORK, ignore_errors=True)
