# AI Subs Player — UI specification

The implementable version of the design in `docs/ux-review/index.html`. Open the report for
the mockups; this file is the contract. It matches the palette already in
`src/index.css`, so most of the colour work is keeping what exists and using it consistently.

The app is a video player. Its chrome sits next to a moving picture, so the surface stays
dark, low contrast and quiet, and colour is spent on state rather than decoration.

---

## Colour

| Token | Value | Role |
|---|---|---|
| `--bg` | `#0b0e14` | Ground: stage chrome, top bar |
| `--bg-2` | `#11151f` | Surface: sidebar, docked panel, transport |
| `--bg-3` | `#171c28` | Raised: buttons, rows, chips |
| `--bg-4` | `#1e2434` | Selected row, active segment |
| `--line` | `#232a3a` | Borders only |
| `--fg` | `#e6e9f0` | Primary text |
| `--fg-dim` | `#9aa3b5` | Secondary text |
| `--fg-faint` | `#66708a` | Tertiary, timecodes, disabled |
| `--accent` | `#5b8cff` | Interactive and progress: primary button, played, translated |
| `--good` | `#3fd07f` | Instant, done, detected |
| `--warn` | `#ffb454` | Transcribing, working, model-guessed gender |
| `--bad` | `#ff6b6b` | Needs attention |

Two rules. Accent means interactive or progress; semantic colours mean state and are never
decorative. Subtitle text on the video is white with a black outline, rendered by libass —
the app never invents a second subtitle style.

## Type and spacing

| Role | Face | Size / weight |
|---|---|---|
| UI text | System (SF Pro) | 13 px / 400–600 |
| Section titles | System | 17 px / 700 |
| Timecodes, paths, model names | SF Mono | 11 px, tabular numerals |
| Target-language cue on video | libass default, Heebo or Arial Hebrew | user-set, default 42 at a 720 reference height |
| Target-language text in panels | Heebo or Arial Hebrew, `direction: rtl` | 13 px / 500 |

4 pt grid. Rows 32 px, controls 28 px, icon buttons 30 px, panel padding 10 px, page padding
16–20 px. Radius: 6 px controls, 8 px rows and menus, 12 px dialogs.

---

## Status vocabulary

Seven states, one `StatusChip` component, one merged status per file path. Nothing else may
describe translation state anywhere in the UI.

| State | Colour | Meaning | Appears in |
|---|---|---|---|
| Instant | good | Fully cached; opening shows the target language immediately | library row, tooltip |
| Ready | dim | Subtitles found; will translate live while you watch | library row |
| Hebrew online | accent-cyan | A human-made file exists online and will be used by default | library row |
| Preparing | accent | Finding subtitles or building context; short | stage pill, library row |
| Transcribing NN% | warn | Whisper is running; long | stage pill, library row, queue |
| Translating NN% | accent | Background or on-demand translation in progress | library row, queue |
| Queued | dim | Waiting in the background queue | library row |
| Needs attention | bad | Something failed; click for the message and an action | library row, stage pill, setup |

---

## Controls inventory

- **Buttons.** One primary per view. Ghost for dismiss. Danger only for destructive actions, always with a confirm that names what is deleted.
- **Segmented control** for two to four mutually exclusive choices switched often: subtitle mode, quality preset, gender. Replaces the true/false selects in Settings.
- **Switch** for on/off with immediate effect. **Select** for lists: models, languages, audio tracks.
- **Path field** is never a bare input. Always: text, a detected-or-not badge, Browse…, and Test where a test is possible.
- **Slider with value** for subtitle size, outline and volume. Value in the mono face; keyboard steps with − and +.
- **Stage pill** top-left of the video for transient prepare state. Never centred over the picture.
- **Toast** bottom-right, five seconds, at most one action.
- **Docked panel** right side, 320 px, shrinks the stage.
- **Dialog** centred, 400–480 px, for decisions only. Title states the situation, options are cards with the recommended one first, Escape picks the safest option.

---

## Keyboard map

| Keys | Action | Keys | Action |
|---|---|---|---|
| `space` `K` | play / pause | `F` `⌃⌘F` | fullscreen |
| `←` `→` | seek ±5 s (shift ±30 s) | `esc` | leave fullscreen, then close panel |
| `J` `L` | seek ±10 s | `M` | mute |
| `↑` `↓` | volume ±5 | `S` | cycle subtitle mode |
| `[` `]` | speed −/+ 0.25 | `,` `.` | subtitle delay −/+ 100 ms |
| `⌘O` `⇧⌘O` | open file / add folder | `⌘1` `⌘2` `⌘3` | library / lines panel / cast panel |
| `⌘E` | export subtitles | `⌘,` | settings |
| `N` `P` | next / previous episode | `⌘F` | search library |

The renderer owns the keymap and forwards to mpv over IPC. mpv keeps
`--no-input-default-bindings`.

---

## Menu bar

**AI Subs Player** · About, Settings ⌘,, Quit
**File** · Open File ⌘O, Add Folder ⇧⌘O, Open Recent ▸, — Choose Subtitle File…, Export Subtitles… ⌘E, — Rescan Library ⌘R, Close Video ⌘W
**Playback** · Play/Pause space, Back 10 s J, Forward 10 s L, — Next Episode N, Previous Episode P, — Speed ▸, Audio Track ▸, Mute M
**Subtitles** · [target] (online), [target] (translated here), [target] + source, source, Off, — Search Online Subtitles…, — Delay −100 ms ",", Delay +100 ms ".", Reset Delay, — Target Language for this Title ▸, Translate Whole File Now, Rebuild Context
**View** · Library ⌘1, Subtitle Lines ⌘2, Cast & Terms ⌘3, — Enter Full Screen ⌃⌘F, Auto-hide Library While Playing
**Help** · Check Setup…, Show Logs, Keyboard Shortcuts ⌘/, — About

---

## Screens

### Setup

Centred column, max 640 px. A short heading, then one row per dependency: status glyph,
name with the resolved path and version underneath, and a fix button on the right. Required
rows gate the primary button and the footer reads "N of 3 required items ready". The model
download row carries a progress bar and a time estimate. Optional rows carry a one-line
reason to care and never block.

### Library

Sidebar 230 px: folders with counts, Add folder…, then the queue with its current item,
progress and a Pause button. Main area: a "Continue watching" strip of four cards with
progress bars, then titles grouped as series and movies.

Row columns: title, status chip, subtitle source and language, length. A thin progress bar
under a row that has a saved position. Right-click gives Play, Play from start, Translate
now, Move to front of queue, Remove from queue, Export subtitles…, Search online
subtitles…, Choose subtitle file…, Rebuild context, Reveal in Finder.

A view toggle switches rows for a poster grid; rows are the default and ship first.

### Player

Video fills the stage. Top-left carries the prepare pill when preparing. Controls reveal on
mouse move and hide after 2.5 s: the three-tone scrub bar with a timecode tooltip, then
previous / −10 / play / +10 / next, elapsed and total in mono, then volume, audio track,
subtitle mode, speed and fullscreen. The scrub legend (played, translated ahead, translated
cached, not yet) shows only while the bar is hovered.

### Docked panel

Header with the tab name and a close button, then tabs for Lines, Cast & terms, Info.

*Lines*: timecode column plus the target line over the source line. The active cue is
highlighted and scrolls into view while "Follow playback" is on. Selecting a row reveals
Edit, Retranslate… and Copy. Pending cues show the source in a dimmed italic.
*Cast & terms*: one row per character with the source name and actor, an editable target
rendering, and a gender segmented control. The gender's provenance is labelled underneath,
and a model guess is amber. Terms follow in a two-column list with an Add term row. The
footer shows re-translation progress and a Save button.
*Info*: poster, synopsis, subtitle source and track language, model in use, cache size.

### Settings

Its own window. Left nav 170 px: General, Subtitles, Translation, Engines, Metadata,
Storage, Advanced. Translation leads with three preset cards, then target language and
model, then two switches, then a collapsed Advanced summary line. Subtitles leads with a
live preview strip on a black ground. Engines is one row per dependency with Browse and
Test, mirroring Setup.

### Dialogs

*No subtitles found*: names the file and its length, says the video keeps playing, then
four option cards in order — download what was found online (recommended when a hash match
exists), transcribe with an estimate, choose a file, play without subtitles — plus a "do
this every time" switch.
*Wrong source language*: names the detected language and offers to translate from it.
*Up next*: names the next episode, says whether it is already translated, counts down from
ten seconds with Stay here and Play now.

---

## Copy rules

Write from the viewer's side of the screen. A control says exactly what happens, and the
confirmation uses the same word: Publish then Published, Export then Exported. Errors say
what went wrong and how to fix it, with no apology. Never show engine vocabulary: no
"bible", "JIT", "ASR", "coverage", "lookahead", "cue index". Say cast and terms,
transcribing, translated, translate ahead, line.
