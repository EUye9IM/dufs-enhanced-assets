# PRD — Play audio files in the player

## Problem

Audio rows have no ▶ action: they are served by the native `<iframe>` path (`.mp3 .ogg .wav
.m4a` in upstream `IFRAME_FORMATS`) or, for everything else (`.flac`, `.m4a`… ), fall through to
"Cannot edit because file is too large or binary." `movi-player` itself handles audio — it has an
`audioonly` attribute, cover art, a cover-art level meter, an audio strip layout and
`getAudioTracks()` — but nothing in this project ever mounts it for an audio file.

## Measured capability of the bundled build

Each extension loaded through the real `assets/movi.js` + `movi.wasm`:

| Extension | Result |
|---|---|
| `.mp3` | ok, 8 s, codec `mp3` |
| `.flac` | ok, 8 s, `flac` |
| `.m4a` / `.m4b` | ok, 8 s, `aac` |
| `.aac` (ADTS) | ok, 8.69 s (estimated duration), `aac` |
| `.ogg` / `.oga` (opus) | ok, 8.01 s, `opus` |
| `.ogg` (vorbis) | ok, 8 s, `vorbis` |
| `.opus` | ok, 8.01 s, `opus` |
| `.wav` | ok, 8 s, `pcm_s16le` |
| `.wma` | ok, 8.03 s, `wmav2` |
| `.mka` | ok, 8 s, `flac` |
| `.aiff` | **error**: "File is corrupted or in an unsupported format" |

## Requirements

R1 — Audio extensions get the ▶ action in the file list, titled "Play audio" (video stays "Play
video").

R2 — `?view` on those extensions mounts `<movi-player>` with `audioonly`, so it renders its audio
strip instead of an empty video surface.

R3 — Only extensions measured above are listed. `.aiff` is excluded, and the list must not grow
on guesswork: a wrong entry produces a ▶ button that leads to an error page.

R4 — Audio extensions are removed from `IFRAME_FORMATS`: the media branch runs first, so those
entries are unreachable dead code.

R5 — Layout: the strip is centred and width-capped, since movi pins its own height and the §6 flex
chain cannot stretch it.

R6 — Video pages are unchanged (player still fills the page, `audioonly` absent).

R7 — `movi.js` / `movi.wasm` stay byte-identical; `bump-assets.sh` runs.

## Out of scope

- Playlist / queue behaviour for audio.
- ID3/cover-art rendering bugs inside movi (only tested with files that have no artwork).
- Streaming formats (HLS/DASH) — the switch is by file extension only.

## Acceptance criteria

A1 — On a directory with all sampled files: 11 rows show "Play audio", `.aiff` keeps "View file".

A2 — `?view` on each of the 11: `movi-player` present, `duration ≈ 8`, `getAudioTracks()` length 1
with the expected codec.

A3 — `audioonly` attribute present, host class list contains `movi-audio-strip`, and the strip
measures 56 px tall, horizontally centred, `body.scrollHeight - innerHeight == 0`.

A4 — Audio plays: press play → state `playing`, clock advances.

A5 — Video page: player bottom == `innerHeight`, `audioonly` absent, `fastseekModes` unchanged.

A6 — `movi.js` / `movi.wasm` sha256 match `UPSTREAM.md`; `node --check assets/index.js` passes;
`index.html` carries fresh `?v=` values after `bump-assets.sh`.
