"""Generate the Guitar Pro 5 demo song used by the tests (needs: pip install pyguitarpro).

    python tools/make_demo_gp5.py [outdir]   -> GP-Link Demo.gp5

Covers what GP-Link reads from .gp5: sections (markers), repeats with alternate endings,
time signature / key / tempo changes, directions, chords, free text, ties, dead/ghost/accented
notes, palm mute, grace notes, tuplets, a second voice, capo, drums and lyrics.
"""
import os
import sys

import guitarpro as gp

HERE = os.path.dirname(os.path.abspath(__file__))
STD = [64, 59, 55, 50, 45, 40]
BASS = [43, 38, 33, 28]

# bar: (num, den, marker, extras)
BARS = [
    (4, 4, "Intro", {"key": (1, 1)}),
    (4, 4, None, {}),
    (4, 4, "Verse", {"open": True, "direction": "Segno"}),
    (4, 4, None, {"alt": 1, "close": 1}),
    (4, 4, None, {"alt": 2}),
    (3, 4, "Chorus", {"tempo": 120}),
    (3, 4, None, {"key": (2, 1), "from": "Da Segno al Coda"}),
    (4, 4, "Outro", {"direction": "Coda"}),
]


def dur(value=4, dotted=False, tuplet=None):
    d = gp.Duration(value=value, isDotted=dotted)
    if tuplet:
        d.tuplet = gp.Tuplet(enters=tuplet[0], times=tuplet[1])
    return d


def beat(voice, notes, d=None, text=None, chord=None, tempo=None, status=gp.BeatStatus.normal):
    b = gp.Beat(voice, duration=d or dur(), status=status)
    if text:
        b.text = text
    if chord:
        c = gp.Chord(len(voice.measure.track.strings))
        c.name = chord
        c.newFormat = True
        c.root = gp.PitchClass(4)
        c.type = gp.ChordType.minor
        c.extension = gp.ChordExtension.none
        c.bass = gp.PitchClass(4)
        c.tonality = gp.ChordAlteration.perfect
        c.fifth = gp.ChordAlteration.perfect
        c.ninth = gp.ChordAlteration.perfect
        c.eleventh = gp.ChordAlteration.perfect
        c.firstFret = 1
        b.effect.chord = c
    if tempo:
        b.effect.mixTableChange = gp.MixTableChange(tempo=gp.MixTableItem(tempo, 0))
    for spec in notes:
        string, fret = spec[0], spec[1]
        opts = spec[2] if len(spec) > 2 else {}
        n = gp.Note(b, value=fret, string=string, type=opts.get("type", gp.NoteType.normal),
                    velocity=opts.get("vel", 95))
        n.effect.ghostNote = opts.get("ghost", False)
        n.effect.accentuatedNote = opts.get("accent", False)
        n.effect.palmMute = opts.get("palm", False)
        n.effect.staccato = opts.get("staccato", False)
        if "grace" in opts:
            n.effect.grace = gp.GraceEffect(fret=opts["grace"], duration=32, velocity=95,
                                            transition=gp.GraceEffectTransition.none)
        b.notes.append(n)
    voice.beats.append(b)
    return b


def make_song(version):
    song = gp.Song()
    song.title = "GP-Link Demo (GP5)"
    song.artist = "GP-Link"
    song.tempo = 100
    song.measureHeaders = []
    song.tracks = []
    for i, (num, den, marker, ex) in enumerate(BARS, 1):
        h = gp.MeasureHeader(number=i)
        h.timeSignature = gp.TimeSignature(numerator=num, denominator=gp.Duration(value=den))
        if marker:
            h.marker = gp.Marker(title=marker, color=gp.Color(255, 0, 0))
        h.isRepeatOpen = ex.get("open", False)
        h.repeatAlternative = ex.get("alt", 0)
        h.repeatClose = ex.get("close", -1)
        if "key" in ex:
            h.keySignature = gp.KeySignature(ex["key"])
        elif i > 1:
            h.keySignature = song.measureHeaders[-1].keySignature
        else:
            h.keySignature = gp.KeySignature((0, 0))
        if version >= (5, 0, 0):
            if "direction" in ex:
                h.direction = gp.DirectionSign(ex["direction"])
            if "from" in ex:
                h.fromDirection = gp.DirectionSign(ex["from"])
        song.addMeasureHeader(h)

    def track(num, name, tuning, offset=0, drums=False):
        t = gp.Track(song, number=num, name=name, offset=offset, isPercussionTrack=drums,
                     strings=[gp.GuitarString(k + 1, v) for k, v in enumerate(tuning)], measures=[])
        t.channel = gp.MidiChannel(channel=9 if drums else num - 1, effectChannel=9 if drums else num - 1,
                                   instrument=0 if drums else 29)
        t.color = gp.Color(40 * num, 100, 200)
        for h in song.measureHeaders:
            t.measures.append(gp.Measure(t, h))
        song.tracks.append(t)
        return t

    gtr = track(1, "Rhythm Gtr", STD, offset=2)          # capo 2
    bass = track(2, "Bass", BASS)
    drums = track(3, "Drums", [0] * 6, drums=True)
    voc = track(4, "Vocals", STD)

    v5 = version >= (5, 0, 0)
    v4 = version >= (4, 0, 0)

    for mi, h in enumerate(song.measureHeaders):
        n = h.timeSignature.numerator
        # guitar
        gv = gtr.measures[mi].voices[0]
        for k in range(n):
            notes = [(6, 0), (5, 2)]
            opts = {}
            if mi == 1 and k == 0:
                beat(gv, [(6, 0), (5, 2)], text="Riff!", chord="Em")
                continue
            if mi == 1 and k == 1:
                beat(gv, [(6, 0, {"type": gp.NoteType.tie}), (5, 2, {"type": gp.NoteType.tie})])
                continue
            if mi == 2 and v4:
                opts = {"palm": True}
            if mi == 3 and k == 3:
                notes = [(6, 0, {"type": gp.NoteType.dead})]
            if mi == 5 and k == 0:
                beat(gv, [(6, 3), (5, 5)], chord="G", tempo=h and 120)
                continue
            if mi == 7 and k == 0 and v4:
                beat(gv, [(3, 4, {"grace": 2})])
                continue
            beat(gv, [(x[0], x[1], x[2] if len(x) > 2 else opts) for x in notes])
        if v5 and mi == 7:
            v2 = gtr.measures[mi].voices[1]
            beat(v2, [(1, 12)], d=dur(1))                   # second voice: whole note
        # bass: eighths, triplets in the last bar
        bv = bass.measures[mi].voices[0]
        if mi == 7:
            for k in range(12):
                beat(bv, [(4, k % 5)], d=dur(8, tuplet=(3, 2)))
        else:
            for k in range(n * 2):
                o = {"ghost": k % 4 == 1, "accent": k % 4 == 0, "vel": 111 if k == 0 else 79}
                beat(bv, [(4, 0 if k % 2 == 0 else 2, o)], d=dur(8))
        # drums: kick/snare + hihat, rest on the last beat of bar 2
        dv = drums.measures[mi].voices[0]
        for k in range(n):
            if mi == 1 and k == n - 1:
                beat(dv, [], status=gp.BeatStatus.rest)
                continue
            beat(dv, [(1, 36 if k % 2 == 0 else 38), (2, 42)])
        # vocals: dotted quarter + eighth pattern, rests in the intro
        vv = voc.measures[mi].voices[0]
        if mi < 2:
            beat(vv, [], d=dur(1), status=gp.BeatStatus.rest) if n == 4 else beat(vv, [], d=dur(2, dotted=True), status=gp.BeatStatus.rest)
        else:
            q = 0
            while q < n:
                if n - q >= 1.5:
                    beat(vv, [(2, 5)], d=dur(4, dotted=True)); beat(vv, [(2, 3)], d=dur(8)); q += 2
                else:
                    beat(vv, [(2, 5)]); q += 1
    if v4:
        song.lyrics = gp.Lyrics(trackChoice=4)
        song.lyrics.lines[0].startingMeasure = 3
        song.lyrics.lines[0].lyrics = "Here we go a-gain, sing-ing a-long to-night and on"
    return song


def main(outdir=None, version=(5, 1, 0), ext="gp5"):
    outdir = outdir or os.path.join(HERE, "..", "examples")
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "GP-Link Demo." + ext)
    gp.write(make_song(version), path, version=version)
    return path


if __name__ == "__main__":
    print("wrote", main(sys.argv[1] if len(sys.argv) > 1 else None))
