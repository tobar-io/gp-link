# GP-Link als REAPER-Erweiterung

> Deutsche Übersetzung. Die Oberfläche von GP-Link ist englisch; Menü- und Dialogbegriffe
> stehen deshalb auf Englisch. Englische Anleitung: [scripts/README.md](../../scripts/README.md).

Eine einzelne Datei: `reaper_gplink-x64.dll` (Download unter Releases) (Windows, 64 Bit, REAPER 6.x/7.x).

## Installation

1. REAPER beenden.
2. `reaper_gplink-x64.dll` nach `%APPDATA%\REAPER\UserPlugins\` kopieren.
3. REAPER starten. Fertig.

Beim Start macht die Erweiterung Folgendes:
- Sie installiert bzw. aktualisiert die GP-Link-Engine in `Scripts\GP-Link\`. Deine `gplink_config.lua` bleibt dabei unangetastet.
- Sie registriert die Actions.
- Sie legt das Menü **Extensions → GP-Link** an.

## Benutzung

- **`.gp`, `.gpx` oder `.gp5` in die Spuransicht ziehen** (aus dem Explorer, wie eine WAV-Datei):
  1. Es erscheint kurz ein Platzhalter-Item.
  2. Dann öffnet sich der Import-Dialog. Als Start-Takt ist der Takt vorgeschlagen, auf dem du die Datei abgelegt hast.
     Dort wählst du die Bausteine (Tempo, Regionen, Marker, Akkorde, MIDI, Lyrics), den Vorzähler
     und pro GP-Spur Häkchen und Ziel-Spur.
  3. Danach entstehen die gewählten Teile: MIDI-Spuren, Tempomap, Regionen, Marker, Spur „Chords“.
- **Auto-Sync** ist standardmäßig an:
  - Speicherst du in Guitar Pro, wird REAPER etwa 2 Sekunden später aktualisiert.
  - Während einer Aufnahme wartet der Sync.
  - Ein- und ausschalten über *Extensions → GP-Link → auto-sync* oder die Action „GP-Link: auto-sync on/off“. Die Action lässt sich auch auf eine Toolbar legen.
- **Import structure only from Guitar Pro**: derselbe Dialog, MIDI und Lyrics sind abgewählt.
  Holt Tempo, Taktarten, Sections, Marker und Akkorde; vorhandene MIDI-Items bleiben unverändert.
- **Sync now**, **Link Guitar Pro file / map tracks** und **Unlink Guitar Pro file** (Spuren bleiben erhalten) findest du ebenfalls im Menü.
- Relative Pfade: Projekt und `.gp` dürfen bei jedem Bandmitglied woanders liegen (z. B. Google Drive),
  solange sie gleich zueinander liegen.

Alles Weitere (Regeln, gesperrte Items, Keyswitches, Einschränkungen) steht in [LIESMICH.md](LIESMICH.md).

## Deinstallation

1. REAPER beenden.
2. `UserPlugins\reaper_gplink-x64.dll` löschen. Optional auch den Ordner `Scripts\GP-Link`.

## Selbst bauen

```bash
pip install ziglang
python extension/build.py
```

`build.py` macht zwei Dinge:
1. Es bettet die Lua-Engine aus `scripts/` in `extension/src/gplink_embedded.h` ein.
2. Es kompiliert mit clang (aus Zig) für `x86_64-windows-gnu`.

Die REAPER-SDK-Header liegen in `sdk/` (Quelle: github.com/justinfrankel/reaper-sdk).
Über die Grenze zu REAPER gehen nur C-Funktionszeiger, deshalb funktioniert die DLL unabhängig vom verwendeten Compiler.

## Aufbau

- `src/gplink_ext.cpp`:
  - Medientypen `.gp`, `.gpx`, `.gp5`: `pcmsrc` mit leerem MIDI-Platzhalter. Ein Timer erkennt das abgelegte Item, merkt sich dessen Position, löscht es und startet den Import.
  - Auto-Sync: Ein Timer prüft jede Sekunde, ob sich die verknüpfte Datei geändert hat (Änderungszeit und Größe). Ist die Datei zweimal hintereinander gleich geblieben, startet er `gplink_autosync_once.lua`. Dieses Skript synchronisiert nur, wenn sich der Inhalt seit dem letzten Sync tatsächlich geändert hat (Vergleich per Hash).
  - Toggle-Action, Menü unter Extensions, Installation der eingebetteten Skripte.
  - Action `GPLINK_IMPORT_DIALOG` (intern): Lua schreibt die Dialog-Beschreibung nach ExtState `GPLINK_DLG/spec`,
    die DLL zeigt den Dialog und schreibt die Antwort nach `GPLINK_DLG/result`.
- `src/gplink_dialog.cpp`: der Import-Dialog (reines Win32, ohne REAPER-Abhängigkeit, einzeln testbar).
- Die eigentliche Logik (GP-Parser, Sync) liegt in Lua: `../GP-Link/gplink_core.lua` und `gplink_reaper.lua`.

Getestet in REAPER 7.52 x64 mit einer separaten Test-Instanz. Dort wurde die `.gp` per Insert Media eingefügt, also über denselben Weg wie beim Ablegen. Ergebnis:
- 9 Spuren mit 2562 Noten
- 9 Regionen
- Start-Takt aus der Einfügeposition
- Auto-Sync nach Dateiänderung

Paket 1 (Import-Dialog) ebenfalls in der Test-Instanz geprüft. Der Dialog wurde per Fernsteuerung bedient
(eine Spur abgewählt, Vorzähler 1, Sections als Marker an). Ergebnis: Spur fehlt wie gewählt, Count-in-Region,
alles um 1 Takt verschoben, Akkordspur, Lyrics, Text-/Tonart-Marker, relativer Pfad nach Speichern und Öffnen.

Echtes Ablegen mit der Maus aus dem Explorer ist noch nicht getestet.
