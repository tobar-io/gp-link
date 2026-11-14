# GP-Link für REAPER

> Deutsche Übersetzung. Die Oberfläche von GP-Link ist englisch; Menü- und Dialogbegriffe
> stehen deshalb auf Englisch. Englische Anleitung: [scripts/README.md](../../scripts/README.md).

Verknüpft ein REAPER-Projekt mit einer Guitar-Pro-Datei: Guitar Pro 7/8 (`.gp`), 6 (`.gpx`) oder 5 (`.gp5`,
speichert auch TuxGuitar).
Guitar Pro bleibt die Quelle für Noten und Arrangement, REAPER für Audio und Mix.
Wenn du in GP speicherst, aktualisiert REAPER die MIDI-Spuren, die Tempomap, die Section-Regionen,
Marker, Akkordspur und Lyrics. Welche dieser Bausteine übernommen werden, wählst du beim Import.

## Installation

1. In REAPER: *Options → Show REAPER resource path in explorer*.
2. Den Ordner `GP-Link` nach `Scripts\` kopieren, also nach `…\REAPER\Scripts\GP-Link\`.
   (Im GitHub-Repo heißt der Ordner `scripts/`; seinen Inhalt nach `Scripts\GP-Link\` kopieren.)
3. *Actions → Show action list → New action… → Load ReaScript…*. Dort diese Dateien laden:
   - `GP-Link - Import Guitar Pro file.lua` ← das reicht für den normalen Workflow
   - `GP-Link - Sync now.lua`
   - `GP-Link - Auto-sync (toggle).lua`
   - `GP-Link - Unlink.lua`
4. Optional: die Actions auf eine Toolbar legen. Auto-Sync zeigt dort an, ob er läuft.

## Mit der GP-Link-Erweiterung (`reaper_gplink-x64.dll`)

Ist die Erweiterung in `UserPlugins` installiert, brauchst du keine Skripte von Hand zu laden:

- **`.gp`/`.gpx`/`.gp5` direkt in die Spuransicht ziehen**, wie eine WAV-Datei. Der Takt, auf dem du die Datei
  ablegst, wird als Start-Takt vorgeschlagen.
- Menü **Extensions → GP-Link**: Link/map tracks, Import structure only, Sync now, Auto-Sync, Unlink.
- Der Import-Dialog ist ein eigenes Fenster mit Häkchen und Auswahllisten (siehe unten).
  Ohne Erweiterung fragen die Skripte stattdessen über einfache Textfelder.
- Auto-Sync läuft eingebaut. Die Action heißt „GP-Link: auto-sync on/off“, der Zustand wird gespeichert.
- Diese Skripte werden beim Start von REAPER automatisch aktualisiert.
  Deine `gplink_config.lua` wird dabei nie überschrieben.

Voraussetzung: Windows 10/11, weil `tar.exe` zum Entpacken genutzt wird. Auf macOS wird `unzip` verwendet.

## Benutzung

**Import**
- `GP-Link - Import` ausführen und die Guitar-Pro-Datei wählen (oder die Datei ins Projekt ziehen).
- Im Import-Dialog legst du fest:
  - **Start bar in REAPER** (Start-Takt): der Takt, auf dem GP-Takt 1 landet.
  - **Count-in (bars)** (Vorzähler): so viele leere Takte kommen vor GP-Takt 1, mit eigener Region „Count-in“.
  - **Import** (Bausteine, einzeln an- und abwählbar):
    - Tempo & Taktarten
    - Sections als Regionen, Sections als Marker
    - Wiederholte Sections nummerieren („Chorus 1“, „Chorus 2“ …)
    - Texte, Sprungzeichen, Tonart als Marker (GP-Text, Segno, Coda, D.S., „Key: E minor“)
    - Akkorde: eigene Spur „Chords“ mit einem leeren Item pro Akkord, Name in den Item-Notizen
    - MIDI-Noten
    - Lyrics: als Lyric-Events in den MIDI-Items (im MIDI-Editor sichtbar)
  - **Spuren**: pro GP-Spur ein Häkchen (übernehmen ja/nein) und das Ziel
    („+ New track“ oder eine vorhandene REAPER-Spur). „All“/„None“ setzen alle Häkchen.
    Ist „MIDI notes“ aus, ist die Spurliste ausgegraut.
- Ohne Erweiterung: Textfelder. Pro GP-Spur `+` = neue Spur, Zahl = vorhandene Spur, `-` = ignorieren.
- Alles wird im Projekt gespeichert (`.rpp`) und beim nächsten Import vorausgewählt.
- Import erneut ausführen:
  - **Nein** behält die Datei und ändert nur Zuordnung oder Start-Takt.
  - **Ja** wählt eine andere GP-Datei.

**Import structure only** öffnet denselben Dialog, aber mit MIDI-Noten und Lyrics abgewählt.
So holst du nur Tempo, Taktarten, Sections, Marker und Akkorde aus Guitar Pro,
z. B. als Gerüst für eine Aufnahme. Vorhandene GP-MIDI-Items bleiben dabei unverändert.

**Sync now** liest die GP-Datei einmal neu ein.

**Auto-Sync (toggle)** läuft im Hintergrund:
- Es prüft jede Sekunde, ob die GP-Datei geändert wurde, und synchronisiert dann automatisch.
- Während einer Aufnahme wartet es, bis die Aufnahme vorbei ist.
- Erneut starten beendet Auto-Sync. REAPER fragt dann, ob das Skript beendet werden soll.

Jeder Sync ist ein eigener Undo-Schritt („GP-Link: Sync“).

## Was synchronisiert wird

| GP | REAPER |
|---|---|
| Spuren (auch mehrere Notensysteme, z. B. Keys) | ein MIDI-Item pro Spur, Take-Name `GP: <Spur>` |
| Noten, Haltebögen, Vorschlagsnoten, Staccato | MIDI-Noten |
| Dynamik ppp–fff, Akzente, Ghost Notes | Velocity |
| Drums (Artikulationen) | GP-Output-MIDI-Noten, Kanal 10 (einstellbar) |
| Tempo- und Taktartwechsel | Tempo- und Taktart-Marker ab dem Start-Takt |
| Sections (Letter/Text) | farbige Regionen (gleicher Buchstabe = gleiche Farbe), optional Marker, Wiederholungen nummeriert |
| Freitexte, Segno/Coda/D.S./D.C./Fine, Tonartwechsel | Marker (gelb) |
| Akkordnamen | Spur „Chords“, ein Item pro Akkord |
| Lyrics (erste Lyrics-Zeile, Notensystem 1) | MIDI-Lyric-Events in den Items der Spur |
| Wiederholungen und Alternativ-Enden | werden ausgeschrieben |
| Simile-Takte (%) | wiederholen den vorherigen Takt |
| Palm Mute / Dead Note / Harmonic | optional Keyswitches pro Spur (`gplink_config.lua`) |

## Regeln

- **Noten nur in Guitar Pro ändern.** Jeder Sync ersetzt die GP-Items komplett.
- **Ein GP-Item sperren** (Item → Lock) friert diese GP-Spur ein: Sie wird beim Sync nicht mehr angefasst.
  So kannst du einzelne Parts in REAPER weiterbearbeiten.
- Audio-Items, FX, Sends, Automation und eigene Regionen bleiben unangetastet.
- Die Tempomap wird ab dem Start-Takt ersetzt, aber nur wenn sie sich in GP geändert hat.
  Bei Tempoänderungen also prüfen, ob die Audio-Aufnahmen noch passen.
- **GP-Item in eine andere Spur ziehen** (z. B. auf eine VSTi-Spur): Der nächste Sync fragt, ob diese GP-Spur
  ab jetzt in die neue Spur synchronisiert werden soll. *Yes* übernimmt die neue Spur, *No* holt das Item zurück.
  Ganze Spuren verschieben (Reihenfolge, Ordner, FX, Umbenennen) braucht keine Rückfrage: Die Verknüpfung folgt der Spur.
- Wenn du eine GP-Spur abwählst oder umhängst, wird ihr altes GP-Item entfernt (außer es ist gesperrt).
- Ist „MIDI notes“ abgewählt, bleiben alle GP-MIDI-Items so, wie sie sind.
- Wählst du Regionen, Marker oder Akkorde ab, werden die von GP-Link angelegten entfernt.
  Eigene Regionen und Marker bleiben immer erhalten.
- Die Akkord-Items kannst du wie GP-Items sperren (Item → Lock), dann bleiben sie beim Sync stehen.

## Band: relative Pfade

Liegen Projekt und `.gp` z. B. in Google Drive, ist der Pfad bei jedem Bandmitglied anders
(`G:\Meine Ablage\…`, `J:\…`). GP-Link speichert deshalb zusätzlich den Pfad **relativ zum Projekt**
(z. B. `..\Songs\Mein Song.gp`). Beim Öffnen sucht GP-Link in dieser Reihenfolge:
1. relativ zum Projekt,
2. der gespeicherte absolute Pfad,
3. eine Datei gleichen Namens im Projektordner.

Wird ein neues Projekt erst nach dem Import gespeichert, ergänzt die Erweiterung den relativen Pfad
automatisch, sobald das Projekt einen Speicherort hat (spätestens beim nächsten Öffnen).

## Noch nicht unterstützt

- Sprungzeichen (D.S., D.C., Coda, Fine). Es gibt einen Hinweis, und die Takte laufen linear durch.
- Bends, Slides, Vibrato als Pitchbend/CC. Tremolo-Picking, Arpeggio/Strum-Timing.
- Guitar Pro 3/4 (`.gp3`, `.gp4`). Die einmal in Guitar Pro öffnen und als `.gp5` oder `.gp` speichern.
- Rückweg REAPER → GP.
- Tab-Ansicht in REAPER (geplant: alphaTab-Seite, die dem REAPER-Playhead folgt).

## Dateien

- `gplink_core.lua`: liest die GP-Datei (eigener XML-Parser) und berechnet daraus die Zeitachse. Unabhängig von REAPER.
- `gplink_reaper.lua`: Entpacken, Projekt-Verknüpfung, Spur-Dialog, Sync.
- `gplink_config.lua`: Einstellungen (MIDI-Kanäle, Velocity, Keyswitches, Prüf-Intervall).
