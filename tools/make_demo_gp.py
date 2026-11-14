"""Generate examples/GP-Link Demo.gp - a small, original demo song in GPIF format.

The file contains exactly the parts of the Guitar Pro 7/8 format that GP-Link reads
(tempo, time signatures, sections, repeats, directions, key changes, chords, lyrics, notes),
so it is used for the tests and the screenshots. It is a test fixture: Guitar Pro itself
expects many more elements and may refuse to open it.

Usage:  python tools/make_demo_gp.py [output.gp]
"""
import os
import sys
import zipfile
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "examples", "GP-Link Demo.gp")

# ---------------------------------------------------------------------------
# song layout (1-based master bars)
# ---------------------------------------------------------------------------
# bar: (time, section, extras)
BARS = []
def add(n, time="4/4", section=None, **kw):
    for i in range(n):
        BARS.append(dict(time=time, section=section if i == 0 else None, **(kw if i == 0 else {})))

add(4, section=("A", "Intro"), key=(1, "Minor"))                     # e-Moll
add(4, section=("B", "Verse"), target="Segno")
add(4, section=("C", "Chorus"), repeat_start=True)                    # played twice
BARS[-1]["repeat_end"] = True
add(4, section=("B", "Verse"))
add(4, section=("C", "Chorus"), key=(2, "Minor"))                     # h-Moll
add(1, time="2/4", section=("D", "Break"))
add(3, section=("E", "Outro"), jump="DaSegnoAlCoda")
TEMPO = [(0, 112), (16, 120)]                                        # (0-based bar, bpm)

# chord progression per section (one chord per bar, guitar plays power chords)
PROG = {
    "Intro": ["E5", "C5", "D5", "B5"], "Verse": ["E5", "E5", "C5", "D5"],
    "Chorus": ["G5", "D5", "E5", "C5"], "Break": ["B5"], "Outro": ["E5", "C5", "D5", "E5"],
}
CHORDS = ["E5", "C5", "D5", "B5", "G5"]
ROOT = {"E5": 40, "C5": 48, "D5": 50, "B5": 47, "G5": 43}          # MIDI root (low)
LYRICS = ("Lights a-cross the wa-ter, wait-ing for the tide, "
          "hold the line to-night, we will not hide")

# ---------------------------------------------------------------------------
class Doc:
    def __init__(self):
        self.rhythms, self.notes, self.beats, self.voices, self.bars = [], [], [], [], []

    def rhythm(self, value):
        if value not in self.rhythms:
            self.rhythms.append(value)
        return self.rhythms.index(value)

    def note(self, props):
        self.notes.append(props)
        return len(self.notes) - 1

    def beat(self, value, notes=(), chord=None, text=None, dyn="MF"):
        self.beats.append(dict(r=self.rhythm(value), notes=list(notes), chord=chord, text=text, dyn=dyn))
        return len(self.beats) - 1

    def voice(self, beats):
        self.voices.append(beats)
        return len(self.voices) - 1

    def bar(self, voice):
        self.bars.append(voice)
        return len(self.bars) - 1


def midi_note(p):
    return f'<Property name="Midi"><Number>{p}</Number></Property>'


def fret_note(string, fret):
    return (f'<Property name="String"><String>{string}</String></Property>'
            f'<Property name="Fret"><Fret>{fret}</Fret></Property>')


def bar_len_qn(time):
    num, den = map(int, time.split("/"))
    return num * 4 / den


def fill(doc, qn, value, step, make_notes):
    """beats of length `step` qn filling `qn`, notes from make_notes(i)"""
    out, i = [], 0
    while qn > 1e-9:
        out.append(doc.beat(value, make_notes(i)))
        qn -= step
        i += 1
    return out


def build():
    d = Doc()
    track_bars = {k: [] for k in ("drums", "bass", "gtr", "vox", "pad")}
    sec = None
    for bi, b in enumerate(BARS):
        if b["section"]:
            sec, k = b["section"][1], 0
        chord = PROG[sec][k % len(PROG[sec])]
        k += 1
        root = ROOT[chord]
        qn = bar_len_qn(b["time"])

        # drums: kick on 1/3, snare on 2/4, hi-hat eighths
        def dn(i):
            ns = [d.note(midi_note(42))]
            if i % 4 == 0: ns.append(d.note(midi_note(36)))
            if i % 4 == 2: ns.append(d.note(midi_note(38)))
            return ns
        beats = fill(d, qn, "Eighth", 0.5, dn) if sec != "Intro" or bi >= 2 else [d.beat("Whole" if qn == 4 else "Half")]
        track_bars["drums"].append(d.bar(d.voice(beats)))

        # bass: root eighths (E string = 0, tuning E1 A1 D2 G2)
        bass_root = root - 12
        s, f = (0, bass_root - 28) if bass_root - 28 < 5 else (1, bass_root - 33)
        track_bars["bass"].append(d.bar(d.voice(fill(d, qn, "Eighth", 0.5, lambda i: [d.note(fret_note(s, f))]))))

        # guitar: power chord quarters, chord symbol on beat 1
        s = 0 if root < 45 else 1
        f = root - (40 if s == 0 else 45)
        gb = []
        for i in range(int(qn)):
            ns = [d.note(fret_note(s, f)), d.note(fret_note(s + 1, f + 2))]
            gb.append(d.beat("Quarter", ns, chord=CHORDS.index(chord) if i == 0 else None,
                             text="Riff!" if bi == 4 and i == 0 else None))
        track_bars["gtr"].append(d.bar(d.voice(gb)))

        # vocals: melody in verses/choruses, rests elsewhere
        if sec in ("Verse", "Chorus"):
            mel = [64, 67, 69, 67] if sec == "Verse" else [71, 69, 67, 66]
            vb = [d.beat("Quarter", [d.note(midi_note(p))]) for p in mel[:int(qn)]]
        else:
            vb = [d.beat("Whole" if qn == 4 else "Half")]
        track_bars["vox"].append(d.bar(d.voice(vb)))

        # pad: whole-bar chord
        pv = "Whole" if qn == 4 else "Half"
        track_bars["pad"].append(d.bar(d.voice([d.beat(pv, [d.note(midi_note(root + 12)), d.note(midi_note(root + 19))], dyn="P")])))
    return d, track_bars


TRACKS = [  # key, name, instrument, type, color, channel, tuning
    ("drums", "Drums", "Drums", "drumKit", "220 80 60", 9, None),
    ("bass", "Bass", "Electric Bass", "electricBass", "60 120 220", 1, "28 33 38 43"),
    ("gtr", "Rhythm Guitar", "Distortion Guitar", "electricGuitar", "230 160 40", 2, "40 45 50 55 59 64"),
    ("vox", "Vocals", "Voice", "voice", "120 200 90", 3, None),
    ("pad", "Synth Pad", "Pad", "synth", "160 100 220", 4, None),
]


def to_xml(d, track_bars):
    x = ['<?xml version="1.0" encoding="utf-8"?>', "<GPIF>", "<GPVersion>8.1.3</GPVersion>",
         "<Score><Title><![CDATA[GP-Link Demo]]></Title><Artist><![CDATA[GP-Link]]></Artist></Score>",
         "<MasterTrack>", "<Tracks>" + " ".join(str(i) for i in range(len(TRACKS))) + "</Tracks>", "<Automations>"]
    for bar, bpm in TEMPO:
        x.append(f"<Automation><Type>Tempo</Type><Linear>false</Linear><Bar>{bar}</Bar>"
                 f"<Position>0</Position><Visible>true</Visible><Value>{bpm} 2</Value></Automation>")
    x += ["</Automations>", "</MasterTrack>", "<Tracks>"]
    for i, (key, name, inst, typ, color, ch, tuning) in enumerate(TRACKS):
        props = ""
        if tuning:
            props += f'<Property name="Tuning"><Pitches>{tuning}</Pitches></Property>'
        if key == "gtr":
            props += '<Property name="DiagramCollection"><Items>' + "".join(
                f'<Item id="{ci}" name="{c}"/>' for ci, c in enumerate(CHORDS)) + "</Items></Property>"
        lyr = ""
        if key == "vox":
            lyr = f"<Lyrics dispatched=\"true\"><Line><Text><![CDATA[{LYRICS}]]></Text><Offset>4</Offset></Line></Lyrics>"
        x.append(f'<Track id="{i}"><Name><![CDATA[{name}]]></Name><Color>{color}</Color>'
                 f"<InstrumentSet><Name>{inst}</Name><Type>{typ}</Type></InstrumentSet>"
                 f"<Staves><Staff><Properties>{props}</Properties></Staff></Staves>"
                 f"<MidiConnection><PrimaryChannel>{ch}</PrimaryChannel></MidiConnection>{lyr}</Track>")
    x += ["</Tracks>", "<MasterBars>"]
    for bi, b in enumerate(BARS):
        m = ["<MasterBar>"]
        if b.get("key"):
            m.append(f"<Key><AccidentalCount>{b['key'][0]}</AccidentalCount><Mode>{b['key'][1]}</Mode></Key>")
        m.append(f"<Time>{b['time']}</Time>")
        if b.get("repeat_start") or b.get("repeat_end"):
            m.append(f'<Repeat start="{str(bool(b.get("repeat_start"))).lower()}" '
                     f'end="{str(bool(b.get("repeat_end"))).lower()}" count="2"/>')
        if b["section"]:
            m.append(f"<Section><Letter><![CDATA[{b['section'][0]}]]></Letter>"
                     f"<Text><![CDATA[{b['section'][1]}]]></Text></Section>")
        if b.get("target") or b.get("jump"):
            m.append("<Directions>" + (f"<Target>{b['target']}</Target>" if b.get("target") else "")
                     + (f"<Jump>{b['jump']}</Jump>" if b.get("jump") else "") + "</Directions>")
        m.append("<Bars>" + " ".join(str(track_bars[t[0]][bi]) for t in TRACKS) + "</Bars>")
        m.append("</MasterBar>")
        x.append("".join(m))
    x += ["</MasterBars>", "<Bars>"]
    x += [f'<Bar id="{i}"><Clef>G2</Clef><Voices>{v} -1 -1 -1</Voices></Bar>' for i, v in enumerate(d.bars)]
    x += ["</Bars>", "<Voices>"]
    x += [f'<Voice id="{i}"><Beats>{" ".join(map(str, v))}</Beats></Voice>' for i, v in enumerate(d.voices)]
    x += ["</Voices>", "<Beats>"]
    for i, b in enumerate(d.beats):
        s = f'<Beat id="{i}"><Dynamic>{b["dyn"]}</Dynamic><Rhythm ref="{b["r"]}"/>'
        if b["chord"] is not None: s += f"<Chord>{b['chord']}</Chord>"
        if b["text"]: s += f"<FreeText><![CDATA[{escape(b['text'])}]]></FreeText>"
        if b["notes"]: s += "<Notes>" + " ".join(map(str, b["notes"])) + "</Notes>"
        x.append(s + "</Beat>")
    x += ["</Beats>", "<Notes>"]
    x += [f'<Note id="{i}"><Properties>{p}</Properties></Note>' for i, p in enumerate(d.notes)]
    x += ["</Notes>", "<Rhythms>"]
    x += [f'<Rhythm id="{i}"><NoteValue>{v}</NoteValue></Rhythm>' for i, v in enumerate(d.rhythms)]
    x += ["</Rhythms>", "</GPIF>"]
    return "\n".join(x)


def main(out=DEFAULT_OUT):
    xml = to_xml(*build())
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("Content/score.gpif", xml)
    print("wrote", os.path.normpath(out))
    return out


if __name__ == "__main__":
    main(*sys.argv[1:2])
