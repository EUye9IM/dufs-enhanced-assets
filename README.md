# dufs-enhanced-assets

An enhanced, drop-in **asset pack** for [dufs](https://github.com/sigoden/dufs) that adds
movi-player (ffmpeg-wasm + WebCodecs) playback, so videos the browser cannot decode
natively — HEVC in Matroska, MPEG-4 Part 2 in AVI, H.264 in MPEG-TS, … — no longer fall
back to a download or show a black frame.

**This repository contains only static assets. It never patches dufs.**

```
index.html  index.css  index.js  favicon.ico   ← dufs frontend, modified
movi.js  movi.wasm                             ← movi-player 0.4.1 dist, byte-identical
```

---

## Deploy

`--assets` is **mandatory**. Without it dufs serves its embedded copies of
`index.js` / `index.css` / `favicon.ico` only, and `movi.js` / `movi.wasm` return 404.

```bash
dufs /srv/files --assets /path/to/dufs-enhanced-assets --allow-upload --allow-delete
```

Any file inside the `--assets` directory is served under the versioned prefix
`/__dufs_v<dufs-version>__/`, e.g. `/__dufs_v0.47.0__/movi.js`. Never hard-code that
prefix — the frontend reads it from a `<meta>` tag that dufs renders.

Requires dufs **0.47.0** or newer (the version whose assets this repo mirrors).

## What it changes

| Where | Behaviour |
|---|---|
| File list, video rows | A **▶ Play video** action opens `<file>?view` in a new tab. Shown regardless of `--allow-upload` / `--allow-delete`. |
| File list, non-video rows | Unchanged. The plain filename link keeps working as a direct/native/download escape hatch. |
| `?view` / `?edit` page, video extension | Loads `movi.js` on demand and mounts `<movi-player src="<file-url>">`, replacing the iframe / "Cannot edit" placeholder. |
| Directory page, text pages | **Zero** extra bytes: `movi.js` (4.8 MB) and `movi.wasm` (5.4 MB) are only fetched on a video view page. |

Decoding is always delegated to movi-player; this project does not try to guess whether
the browser could decode a file natively (that guess cannot be made reliably from a
filename, and a failed guess reproduces the original black-frame bug).

### Degradation

Any failure keeps the file downloadable and the page usable:

| Failure | Result |
|---|---|
| `movi.js` 404 / network error | "Failed to load video player. You can still download the file." |
| `movi.wasm` fetch or instantiation error, unsupported codec | "This video could not be decoded. You can still download the file." |

## Browser support

Playback needs WebCodecs and WebAssembly. Latest Chrome / Edge / Safari (16.4+) are
targeted. Firefox lacks WebCodecs, so it falls back to full software decoding — it works
but is slow for HD/4K. Mobile is **not** a committed target: an iPhone cannot enter true
full-screen for a canvas-based player.

## Known issues

| Issue | Notes |
|---|---|
| Outbound font request | `movi.js` injects `@import url('https://fonts.googleapis.com/css2?family=Inter…')` into its shadow root. On an offline/LAN deployment this is one failed request per player page; playback is unaffected and it falls back to system fonts. Would need CSP or a self-hosted font to remove. |
| Concurrent tabs | Each tab owns its own wasm instance and decode buffers. Opening many videos at once multiplies memory; not optimised. |
| 4K on low-end devices | Not tested; wasm memory pressure is real. |
| Files > 4 GB | Not tested (32-bit offset risk inside the wasm demuxer). |
| Basic/Digest auth | Verified working for playback and seek. Note that credentials embedded in the URL (`http://u:p@host/`) break it: movi derives `movi.wasm` from `document.currentScript.src` and `fetch()` rejects URLs containing credentials. Normal auth flows (browser prompt + credential cache) are fine. |

## Layout

```
index.html            dufs shell + <meta name="dufs-assets-prefix">
index.js              dufs frontend + play action + lazy movi-player mount
index.css             dufs styles + player sizing
favicon.ico
movi.js               movi-player 0.4.1 dist/element.slim.global.js
movi.wasm             movi-player 0.4.1 dist/movi.wasm
sync-movi.sh          re-download both movi files for another version
UPSTREAM.md           exact upstream versions + how to sync dufs assets
NOTICE.md             third-party licences
LICENSE-MIT           dufs assets
LICENSE-APACHE        dufs assets
LICENSE-LGPL-2.1.txt  FFmpeg inside movi.wasm
```

## Updating movi-player

```bash
./sync-movi.sh 0.4.2        # download, verify, replace movi.js + movi.wasm
git diff --stat             # expect exactly those two files
```

## Large files

`movi.js` (4.8 MB) and `movi.wasm` (5.4 MB) are tracked as ordinary files. That keeps
`git clone` free of any extra tooling and lets `git archive` / tarball deployment work.
Every movi upgrade adds ~10 MB to history. If that becomes a problem, convert once with:

```bash
git lfs migrate import --include="movi.js,movi.wasm"
```

`sync-movi.sh` keeps working unchanged after such a conversion.

## Licence

The dufs frontend files are derived from dufs and stay under **MIT OR Apache-2.0**
(`LICENSE-MIT`, `LICENSE-APACHE`). `movi.wasm` statically links FFmpeg, so
**LGPL-2.1-or-later** applies to it (`LICENSE-LGPL-2.1.txt`). `movi.js` is Apache-2.0.
Third-party components and what redistribution obliges you to do are listed in
`NOTICE.md` — read it before publishing this repository or serving it publicly.
