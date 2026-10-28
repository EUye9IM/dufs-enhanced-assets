# movi-player cannot decode `mov_text` (tx3g) subtitles

Status: **backlog / not scheduled** (recorded 2026-10-28 from a live bug report).

## Problem

A file whose subtitles are MP4 `mov_text` (`tx3g`) plays with **no subtitles and no error**,
even though the track exists and the player is otherwise healthy. Example:
`/dl/【10月】与暗黑召唤师秘密恋爱中 04【完全无修版】.mp4` (650 MB, ffprobe: 2 × `mov_text`,
`chi` default + `zho`).

## Evidence (measured, dufs 0.47.0 + movi-player 0.4.1, Chrome 154)

1. **Demuxer is fine** — `player.trackManager.getSubtitleTracks()` returns both tracks:
   `{id:3, type:"subtitle", codec:"mov_text", subtitleType:"text", language:"chi", duration:719.99}`.
2. **Pipeline runs** — with the track selected, `__movilog` shows
   `Processing subtitle packet: stream=3, size=105, timestamp=3.149s`.
3. **WASM is the wall** —
   `D [movi:SubtitleDecoder] Skipping decode: configured=false, bindings=true, track=false`
   then `W [movi:Bindings] prefetchSubtitleCues: failed (-2)`.
   `-2` is documented in `src/decode/SubtitleDecoder.ts` as
   *"Subtitle codec '…' not found/not compiled in WASM build"*.
4. **Secondary UX bug** — after a failed `configure()` the element shows no subtitle entry and
   no message; the only trace is one debug line per subtitle packet.
5. **Data itself is trivial** — a 60-line parser over HTTP Range
   (`moov → trak(hdlr=sbtl) → stbl(stts/stsc/stsz/stco) → sample`) pulled real cues out of the
   file: `[3149.000 → 5735.000] '《与暗黑召唤师秘密恋爱中》\n[快做吧！ 快做吧！]…'`.
   `tx3g` payload = 2-byte big-endian length + UTF-8, optional style boxes.
6. **Ruled out**: `ffmpeg … -c:s webvtt out.mp4` (mp4 muxer rejects it, `-22`); remuxing to
   MKV + `subrip` (movi still reports no track — its text whitelist is `vtt|wvtt|stpp`).
7. **Verified workaround**: a `<track kind="subtitles" src="…srt" srclang label default>` child
   on `<movi-player>` renders correctly (blob: URL works, cue text confirmed on screen).

## Options (from the analysis)

| # | Path | Cost | Notes |
|---|---|---|---|
| P1 | Upstream: enable `mov_text` decoder in movi's WASM build + surface the failure | issue/PR + release wait | Root fix; keeps our assets byte-identical |
| P2 | Shim in `assets/index.js`: detect unsupported subtitle codec, extract `tx3g` over Range, emit WebVTT blob as a `<track>` | ~250 lines, no build step | Progressive MP4 only; ignores tx3g styling; ~300 small ranges per episode |
| P3 | Server-side `ffmpeg -map 0:s:0? -c:s srt` batch | media library touch | No client code |
| P4 | Fork + rebuild wasm ourselves | high | Breaks the byte-identical rule |

Recommendation when this is picked up: **P1 + P2 in parallel**; P2 self-disables once the
codec is supported (`if codec not in supported set`).

## Out of scope

- Image subtitles (PGS/VOBSUB) — separate topic.
- Any change to `movi.js` / `movi.wasm` bytes.

## Acceptance criteria (when scheduled)

- A1 A progressive MP4 with `mov_text` subtitles shows text at the correct times.
- A2 A file with `srt`-in-MKV or `wvtt`-in-MP4 is unaffected (no duplicate track).
- A3 A fragmented MP4 falls back gracefully (no console spam, no crash).
- A4 `movi.js` / `movi.wasm` SHA-256 unchanged.
