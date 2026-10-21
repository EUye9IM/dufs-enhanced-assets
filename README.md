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

## Performance: HTTPS is required for hardware decoding

This matters more than any other setting here, so it is not buried under known issues.

**WebCodecs (`VideoDecoder` / `AudioDecoder`) is only exposed in a secure context.** Browsers
treat `https://…` and `http://localhost` as secure, but **not** `http://192.168.1.100:24601`.
On a plain-HTTP LAN origin `typeof VideoDecoder === "undefined"`, so movi-player cannot use
hardware decoding and falls back to ffmpeg-wasm software decoding **on the main thread**.

Measured on a 1080p H.264 MKV (1.29 GB, 0.73 MB/s realtime bitrate) over Gigabit LAN:

| Path | Decoded frames | Playback progress | Verdict |
|---|---|---|---|
| Native `<video>` from the filename link | 120 frames / 5 s (24 fps), 0 dropped | realtime | smooth |
| movi-player over `http://<lan-ip>` | 38 frames / 6.1 s (**6.2 fps**) | 3.5 s in 6.1 s (**57 %**) | stutters, UI janky |
| movi-player with WebCodecs available | — | 5.8 s in 6.1 s (95 %) | realtime |

Network was never the constraint: fetching a single 8 MB range from the same page takes
0.51 s (**15.7 MB/s**) when the player is paused, while realtime playback needs 0.73 MB/s.
During playback the same fetches slow down because the main thread is busy decoding.

When the player detects `!isSecureContext`, it now shows this warning above the video.

### Fix 1 — serve dufs over HTTPS (recommended)

```bash
# Self-signed certificate valid for one IP + hostname (OpenSSL 1.1.1+ for -addext)
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout dufs.key -out dufs.crt \
  -subj "/CN=dufs-lan" \
  -addext "subjectAltName=IP:192.168.1.100,DNS:tiny04"

# dufs serves TLS natively — no reverse proxy needed
dufs /dl --assets /path/to/dufs-enhanced-assets \
  --tls-cert dufs.crt --tls-key dufs.key \
  --bind 0.0.0.0 --port 24601
```

**The certificate must be trusted**, otherwise the browser still treats the page as insecure
and WebCodecs stays disabled. Trust it on each client once:

| Platform | Command |
|---|---|
| Linux | `sudo cp dufs.crt /usr/local/share/ca-certificates/dufs-lan.crt && sudo update-ca-certificates` (then restart the browser) |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain dufs.crt` |
| Windows | `certmgr.msc` → Trusted Root Certification Authorities → Import |
| Firefox | has its own store: Settings → Privacy → Certificates → View Certificates → Import |

Verify afterwards — on the player page's console:

```js
isSecureContext   // true
typeof VideoDecoder  // "function"
```

Alternatives if you would rather not manage a self-signed cert: use `mkcert` (local CA),
put dufs behind a reverse proxy with a real certificate, or front it with something like
Caddy that issues its own local CA.

### Fix 2 — client-side flag (quick, per-machine)

Chrome/Chromium:

1. `chrome://flags/#unsafely-treat-insecure-origin-as-secure`
2. Add `http://192.168.1.100:24601` and enable the flag, then restart the browser.

Or launch with the same setting:

```bash
chrome --unsafely-treat-insecure-origin-as-secure=http://192.168.1.100:24601
```

This weakens the browser's origin security model for that origin (no secure-transport
guarantees, service workers / powerful APIs become available). Fine for a trusted home
LAN, not something to hand out to other users — prefer Fix 1.

### Not the fix: the direct filename link

The filename link bypasses the player and lets the browser play the file with its own
hardware decoder, which is why it looks smooth on files the browser can demux. Two
caveats: the browser may not support the container/codec at all (that is why this asset
pack exists), and it will silently drop audio codecs it cannot decode — the `DDP5.1`
(E-AC3) releases above play fine natively but **without sound**.

## Known issues

| Issue | Notes |
|---|---|
| Outbound font request | `movi.js` injects `@import url('https://fonts.googleapis.com/css2?family=Inter…')` into its shadow root. On an offline/LAN deployment this is one failed request per player page; playback is unaffected and it falls back to system fonts. Would need CSP or a self-hosted font to remove. |
| Concurrent tabs | Each tab owns its own wasm instance and decode buffers. Opening many videos at once multiplies memory; not optimised. |
| 4K on low-end devices | Not tested; wasm memory pressure is real. |
| Files > 4 GB | Not tested (32-bit offset risk inside the wasm demuxer). |
| Basic/Digest auth | Verified working for playback and seek. Note that credentials embedded in the URL (`http://u:p@host/`) break it: movi derives `movi.wasm` from `document.currentScript.src` and `fetch()` rejects URLs containing credentials. Normal auth flows (browser prompt + credential cache) are fine. |
| Plain-HTTP LAN playback | Slow by design until served over HTTPS — see [Performance: HTTPS is required for hardware decoding](#performance-https-is-required-for-hardware-decoding). The player shows an in-page warning when it detects `!isSecureContext`. |

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
