# LCT for Windows — user guide

## Start, pause, stop

- **start / stop**: the green button bottom-right, the tray menu, or `Ctrl+Alt+S`.
  While starting, LCT makes sure Ollama is up and the speech model is present.
- **pause / resume**: `⏸`, the tray menu, or `Ctrl+Alt+P`. Pausing finalizes
  the sentence in progress and parks new lines as *pending*; resume translates
  them in order.
- **clear**: `🗑` (only while stopped) empties the transcript and the session
  export.

## The status bar

`● rec 01:23` — capture state and elapsed time (orange while paused).

`SYS ZH · MIC EN → JA` — click to change each channel's recognition language or
the target language. Changes apply live; only the affected channel restarts.

`● qwen3.5:4b · 412 ms` — the Ollama indicator (green = reachable; click a red
one to start Ollama), the translation model (hover for its memory state) and
the latency of the last translation.

`⤓ ⟲ ⇪ ⚙` — auto-scroll, history, export (Markdown / text / SRT), settings.

## Transcript

Each finalized line shows its time, a `SYS` or `MIC` badge, the recognized text
and the translation as it streams in. The highlighted line at the bottom is the
live draft: what is being said right now and, when live draft translation is
on, its provisional translation.

Notices appear under the status bar with a button for the fix: start Ollama,
download a model, open the microphone privacy page, retry capture.

## Overlay

`Ctrl+Alt+O` or the tray menu toggles the floating subtitle window. Drag it to
move, pull its edges to resize; LCT remembers the placement. Hover to reveal
pause, copy and hide. Opacity, font size, stay-on-top and click-through are in
Settings ▸ Display & Overlay.

## Tray

Closing the main window keeps LCT running in the tray (configurable). The tray
menu shows the window, toggles the overlay, starts/stops/pauses, opens Settings
and exits.

## Export

`⇪` exports the whole current session, both channels interleaved:

- **Markdown** — header with duration and languages, one block per line.
- **Text** — the same as plain text.
- **SRT** — subtitle cues timed from each line's finalization.

## History

Off by default. Turn it on in Settings ▸ History to keep finalized lines in
`%LOCALAPPDATA%\LCT\history.db` with a retention period and a maximum count.
`⟲` opens it: search, copy, delete one entry, clear all, export CSV.

## Diagnostics

Settings ▸ Diagnostics ▸ **Export Diagnostics…** writes a text file with
versions, hardware, settings and Ollama status — never transcripts. **Show Log
Folder** opens `%LOCALAPPDATA%\LCT\logs\`.
