# dufs-enhanced-assets

An enhanced, drop-in **asset pack** for [dufs](https://github.com/sigoden/dufs) that adds
movi-player (ffmpeg-wasm + WebCodecs) playback, so videos the browser cannot decode
natively — HEVC in Matroska, MPEG-4 Part 2 in AVI, H.264 in MPEG-TS, … — no longer fall
back to a download or show a black frame.

**This repository contains only static assets. It never patches dufs.**

```
assets/            ← the only directory passed to dufs --assets
  index.html  index.css  index.js  favicon.ico   ← dufs frontend, modified
  movi.js  movi.wasm                             ← movi-player 0.4.1 dist, byte-identical
  trust/                                         ← trust page + published CA certificate
scripts/gen-tls.sh ← mints the local TLS material for HTTPS
sync-movi.sh       ← moves movi-player to another version
```

---

## Deploy

`--assets` is **mandatory**, and it must point at the `assets/` subdirectory. Without it
dufs serves its embedded copies of `index.js` / `index.css` / `favicon.ico` only, and
`movi.js` / `movi.wasm` return 404.

```bash
dufs /srv/files --assets /path/to/dufs-enhanced-assets/assets --allow-upload --allow-delete
```

The rest of the repository (`scripts/`, `tls/`, the docs, the licences) deliberately sits
*outside* `assets/`, because everything inside `assets/` is served over HTTP. Keep it that
way: the directory is a public namespace, so no private key may ever live in it.

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

When the player is opened over a connection the browser does not trust, it shows a warning above
the video that links to the trust page described below.

#### How the player notices an untrusted certificate

No web API exposes certificate trust: `isSecureContext` only looks at the **scheme**, so a page
reached by clicking through the browser warning is still a secure context and everything works —
WebCodecs, hardware decoding, the works. That is why the player cannot simply ask "am I safe?".

What it does instead is register a two-line service worker (`assets/trust/probe-sw.js`). The
service worker script fetch is the one same-origin request that does **not** inherit the
click-through exception, so registration fails with `An SSL certificate error occurred` exactly
when the certificate is untrusted, and succeeds when the CA is installed. The registration is
unregistered immediately; nothing is cached or intercepted.

| Outcome | Hint |
|---|---|
| registration threw with a certificate/SSL message | shown, links to the trust page |
| registration succeeded (CA installed) | hidden |
| no service worker API, or the failure was something else | hidden — a broken deployment never accuses a correctly configured visitor |

Consequence worth knowing: Chrome still labels such a page *Not secure*, and it is right to —
that is about **authentication** (anyone on the LAN can impersonate the server), not about what
the page is allowed to do. Installing the CA clears both the browser label and this hint.

### Fix 1 — serve dufs over HTTPS (recommended)

One command mints all the TLS material:

```bash
./scripts/gen-tls.sh
#   --host <ip|name>    add SAN entries if autodetection misses yours (repeatable)
#   --force             re-issue the server certificate even if still valid
#   --verify            only re-run the sanity checks
```

It creates a **private CA** (10 years) plus a server certificate (825 days) whose SAN covers
every LAN address the machine currently has, its hostname, and loopback, then prints the
exact dufs invocation:

```bash
dufs /srv/files --assets /path/to/dufs-enhanced-assets/assets \
  --tls-cert tls/dufs.crt --tls-key tls/dufs.key \
  --bind 0.0.0.0 --port 24601
```

Why a CA instead of a single self-signed certificate: browsers ignore the CN and match the
SAN against the address you actually typed, so a self-signed certificate stops working the
moment the LAN IP changes — and every device has to re-trust it. With a private CA you
install the CA once, and re-running `./scripts/gen-tls.sh` re-issues only the server
certificate, invisibly to every device.

The CA is generated on the server and never leaves it. No public CA, no ACME, no external
dependency. `tls/` is gitignored; the only published material is the CA **certificate**
(a public key) and the iOS profile.

**Then trust the CA, once per device.** Nothing has to be copied between machines — this page
serves the certificate and the per-platform steps, and the player's warning links straight to
it:

```
https://<lan-ip>:24601/__dufs_v<dufs-version>__/trust/index.html
```

The first visit passes through the browser's certificate warning (nothing is trusted yet):
proceed once, install the CA, reload — the warning is gone for good.

| Platform | One-time install |
|---|---|
| Linux | `sudo cp ca.crt /usr/local/share/ca-certificates/dufs-lan.crt && sudo update-ca-certificates`; Chromium/Firefox also read NSS: `certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n dufs-lan -i ca.crt`; restart the browser |
| macOS | double-click `ca.crt`, then Keychain Access → the certificate → Trust → *Always Trust*; or `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt` |
| Windows | `certmgr.msc` → Trusted Root Certification Authorities → Import (not "Personal") |
| Android | Settings → Security → Encryption & credentials → Install a certificate → **CA certificate**. Chrome trusts user CAs; Firefox for Android does not |
| iOS / iPadOS | install the `.mobileconfig` profile, **then** Settings → General → About → Certificate Trust Settings → enable full trust. Both steps are required |
| Firefox (desktop) | has its own trust store: Settings → Privacy & Security → Certificates → View Certificates → Import, tick "Trust this CA to identify websites" |

> **"Proceed anyway" is not trust.** Clicking through the warning only bypasses it for that
> session, leaves the origin unauthenticated, and has to be repeated — the player keeps showing
> its warning on every visit until the CA is installed. Verify the CA fingerprint first if the
> network is not fully trusted:
> `openssl x509 -noout -fingerprint -sha256 -in assets/trust/ca.crt` must match the
> `CA SHA-256` line printed by `scripts/gen-tls.sh`.

Not fixable from the page: a web page cannot install a certificate into the OS trust store,
and the server's private key cannot be generated in the browser — dufs loads it from disk at
startup. Trust installation stays a one-time manual step per device.

Verify afterwards — on the player page's console:

```js
isSecureContext                    // true (this says nothing about the certificate)
typeof VideoDecoder                // "function"
document.querySelector('.movi-hint')  // null once the CA is trusted
```

A publicly-trusted name (real domain, overlay network, tunnel) would remove the install step
entirely, but that is deliberately out of scope here — this pack is meant to work on a LAN
with no external dependency. The zero-install escape hatch is a loopback origin:
`ssh -L 24601:localhost:24601 user@server`, then open `http://localhost:24601` — a loopback
origin is already a secure context, so WebCodecs works with no certificate at all. It only
helps the machine holding the tunnel.

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
| Plain-HTTP LAN playback | Slow by design until served over HTTPS — see [Performance: HTTPS is required for hardware decoding](#performance-https-is-required-for-hardware-decoding). Over plain HTTP the player shows no warning at all: this deployment is TLS-only, and an insecure origin cannot run the service worker probe that would detect anything. |

## Layout

```
assets/                  ← passed to dufs --assets; everything here is served over HTTP
  index.html             dufs shell + <meta name="dufs-assets-prefix">
  index.js               dufs frontend + play action + lazy movi-player mount
  index.css              dufs styles + player sizing + certificate-trust hint
  favicon.ico
  movi.js                movi-player 0.4.1 dist/element.slim.global.js
  movi.wasm              movi-player 0.4.1 dist/movi.wasm
  trust/index.html       "trust this server" page: what/why + per-platform steps
  trust/ca.crt           generated by scripts/gen-tls.sh, gitignored (public key)
  trust/*.mobileconfig   generated iOS profile, gitignored (public key)
scripts/gen-tls.sh       mint the private CA + server certificate + iOS profile
tls/                     generated TLS material, gitignored, NEVER served
  ca.key  ca.crt  dufs.key  dufs.crt
sync-movi.sh             re-download both movi files for another version
UPSTREAM.md              exact upstream versions + how to sync dufs assets
NOTICE.md                third-party licences
LICENSE-MIT              dufs assets
LICENSE-APACHE           dufs assets
LICENSE-LGPL-2.1.txt     FFmpeg inside movi.wasm
```

## Updating movi-player

```bash
./sync-movi.sh 0.4.2        # download, verify, replace assets/movi.js + assets/movi.wasm
git diff --stat             # expect exactly those two files
```

## Large files

`assets/movi.js` (4.8 MB) and `assets/movi.wasm` (5.4 MB) are tracked as ordinary files. That
keeps `git clone` free of any extra tooling and lets `git archive` / tarball deployment work.
Every movi upgrade adds ~10 MB to history. If that becomes a problem, convert once with:

```bash
git lfs migrate import --include="assets/movi.js,assets/movi.wasm"
```

`sync-movi.sh` keeps working unchanged after such a conversion.

## Licence

The dufs frontend files are derived from dufs and stay under **MIT OR Apache-2.0**
(`LICENSE-MIT`, `LICENSE-APACHE`). `movi.wasm` statically links FFmpeg, so
**LGPL-2.1-or-later** applies to it (`LICENSE-LGPL-2.1.txt`). `movi.js` is Apache-2.0.
Third-party components and what redistribution obliges you to do are listed in
`NOTICE.md` — read it before publishing this repository or serving it publicly.
