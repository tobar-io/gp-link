# GP-Link for REAPER – manual

GP-Link links a REAPER project to a Guitar Pro file: Guitar Pro 7/8 (`.gp`), 6 (`.gpx`) or 5 (`.gp5`,
also saved by TuxGuitar).
Guitar Pro stays the source for notes and arrangement, REAPER the place for audio and mixing.
Whenever you save in Guitar Pro, REAPER updates the MIDI tracks, tempo map, section regions,
markers, chord track and lyrics. You choose which of these parts are imported.

## Installation

**Recommended: the extension.** Copy `reaper_gplink-x64.dll` to `%APPDATA%\REAPER\UserPlugins\` and
restart REAPER. The extension installs these scripts to `Scripts\GP-Link\` and keeps them up to date.
Your `gplink_config.lua` is never overwritten.

**Scripts only (no extension):**
1. In REAPER: *Options → Show REAPER resource path in explorer*.
2. Copy this folder to `Scripts\GP-Link\`.
3. *Actions → Show action list → New action… → Load ReaScript…* and load:
   - `GP-Link - Import Guitar Pro file.lua` ← enough for the normal workflow
   - `GP-Link - Import structure only.lua`
   - `GP-Link - Sync now.lua`
   - `GP-Link - Auto-sync (toggle).lua`
   - `GP-Link - Unlink.lua`
4. Optional: put the actions on a toolbar. Auto-sync shows there whether it is running.

Requirements: Windows 10/11 (`tar.exe` is used to unpack the `.gp`). On macOS the scripts use `unzip`;
the extension is Windows-only.

## With the extension (`reaper_gplink-x64.dll`)

- **Drag a `.gp`/`.gpx`/`.gp5` straight onto the arrange view**, like a WAV file. The bar you drop it on is suggested
  as the start bar.
- Menu **Extensions → GP-Link**: link/map tracks, import structure only, sync now, auto-sync, unlink.
- The import dialog is a native window with checkboxes and drop-down lists (see below).
  Without the extension the scripts ask through plain text fields instead.
- Auto-sync is built in. The action is called "GP-Link: auto-sync on/off"; its state is saved.

## Usage

**Import**
- Run `GP-Link - Import Guitar Pro file` and choose the Guitar Pro file (or drop the file into the project).
- In the import dialog you set:
  - **Start bar in REAPER**: the bar where GP bar 1 lands.
  - **Count-in (bars)**: that many empty bars are inserted before GP bar 1, with their own "Count-in" region.
  - **Import** (parts, each can be switched on or off):
    - Tempo & time signatures
    - Sections as regions, sections as markers
    - Number repeated sections ("Chorus 1", "Chorus 2" …)
    - Text, jumps, key changes as markers (GP free text, Segno, Coda, D.S., "Key: E minor")
    - Chords: a track "Chords" with one empty item per chord, name in the item notes
    - MIDI notes
    - Lyrics: as lyric events in the MIDI items (visible in the MIDI editor)
  - **Tracks**: per GP track a checkbox (import yes/no) and the target
    ("+ New track" or an existing REAPER track). "All"/"None" set all checkboxes.
    With "MIDI notes" off, the track list is greyed out.
- Without the extension: text fields. Per GP track `+` = new track, number = existing track, `-` = skip.
- Everything is stored in the project (`.rpp`) and preselected on the next import.
- Running the import again on a linked project:
  - **No** keeps the file and only changes parts, tracks or start bar.
  - **Yes** chooses another GP file.

**Import structure only** opens the same dialog with MIDI notes and lyrics unchecked.
It takes tempo, time signatures, sections, markers and chords from Guitar Pro,
e.g. as a skeleton for a recording. Existing GP MIDI items stay as they are.

**Sync now** re-reads the GP file once.

**Auto-sync (toggle)** runs in the background:
- It checks every second whether the GP file changed and then syncs automatically.
- While recording it waits until recording has stopped.
- Running it again stops auto-sync. REAPER then asks whether to terminate the script.

Every sync is one undo step ("GP-Link: Sync").

## What is synced

| Guitar Pro | REAPER |
|---|---|
| Tracks (also multiple staves, e.g. keys) | one MIDI item per track, take name `GP: <track>` |
| Notes, ties, grace notes, staccato | MIDI notes |
| Dynamics ppp–fff, accents, ghost notes | velocity |
| Drums (articulations) | GP output MIDI notes, channel 10 (configurable) |
| Tempo and time signature changes | tempo/time signature markers from the start bar on |
| Sections (letter/text) | coloured regions (same letter = same colour), optional markers, repeats numbered |
| Free text, Segno/Coda/D.S./D.C./Fine, key changes | markers (yellow) |
| Chord names | track "Chords", one item per chord |
| Lyrics (first lyrics line, staff 1) | MIDI lyric events in the track's item |
| Repeats and alternate endings | written out |
| Simile bars (%) | repeat the previous bar |
| Palm mute / dead note / harmonic | optional keyswitches per track (`gplink_config.lua`) |

## Rules

- **Edit notes in Guitar Pro only.** Every sync replaces the GP items completely.
- **Locking a GP item** (Item → Lock) freezes that GP track: it is no longer touched by a sync.
  That way you can keep editing single parts in REAPER.
- Audio items, FX, sends, automation and your own regions are never touched.
- The tempo map is replaced from the start bar on, but only if it changed in GP.
  After tempo changes, check whether your audio recordings still fit.
- **Moving a GP item to another track** (e.g. onto a VSTi track): the next sync asks whether that GP track
  should sync into the new track from now on. *Yes* remaps it, *No* moves the item back.
  Moving whole tracks (reorder, folders, FX, renaming) needs no question: the link follows the track.
- If you uncheck or remap a GP track, its old GP item is removed (unless it is locked).
- With "MIDI notes" unchecked, all GP MIDI items stay as they are.
- Unchecking regions, markers or chords removes the ones GP-Link created.
  Your own regions and markers are always kept.
- Chord items can be locked like GP items (Item → Lock); they then stay put during a sync.

## Bands: relative paths

If the project and the `.gp` live in a shared folder (Google Drive, Dropbox …), the path differs on
every band member's machine (`G:\My Drive\…`, `J:\…`). GP-Link therefore also stores the path
**relative to the project** (e.g. `..\Songs\My Song.gp`). When opening a project it looks for the file:
1. relative to the project,
2. at the stored absolute path,
3. as a file with the same name in the project folder.

If a new project is saved only after the import, the extension adds the relative path automatically
as soon as the project has a location (at the latest when it is opened again).

## Not supported yet

- Jumps (D.S., D.C., Coda, Fine) are shown as markers, but bars play linearly (no jump is written out).
- Bends, slides, vibrato as pitch bend/CC. Tremolo picking, arpeggio/strum timing.
- Guitar Pro 3/4 files (`.gp3`, `.gp4`): open them once in Guitar Pro and save as `.gp5` or `.gp`.
- The way back, REAPER → Guitar Pro.
- User interface in other languages (the UI is English).

## Files

- `gplink_core.lua`: reads the GP file (own XML parser) and builds the timeline. Independent of REAPER.
- `gplink_reaper.lua`: unpacking, project link, import dialog, sync.
- `gplink_config.lua`: settings (MIDI channels, velocity, keyswitches, polling interval).
- `gplink_autosync_once.lua`: one-shot sync, called by the extension's auto-sync timer.
