# NOTICE

This repository redistributes third-party software. Keep this file with any copy of the
repository and with any deployment that serves these assets publicly.

---

## 1. dufs frontend assets — MIT OR Apache-2.0

`index.html`, `index.css`, `index.js`, `favicon.ico` are derived from
[dufs](https://github.com/sigoden/dufs) v0.47.0 (`assets/` directory).

```
Copyright (c) sigoden(2022)
```

Licensed under either of MIT (`LICENSE-MIT`) or Apache License 2.0 (`LICENSE-APACHE`),
at your option. Files were modified: a play action was added to the file list, a
`<meta name="dufs-assets-prefix">` tag was added, and the `?view` page now mounts
movi-player for video files.

## 2. movi-player — Apache-2.0

`movi.js` is an unmodified copy of `movi-player@0.4.1` `dist/element.slim.global.js`.

```
movi-player — https://github.com/mrujjwalg/movi-player — https://moviplayer.com
Licensed under the Apache License, Version 2.0
```

Plain-text licence: https://www.apache.org/licenses/LICENSE-2.0

## 3. FFmpeg (linked into movi.wasm) — LGPL-2.1-or-later

`movi.wasm` is an unmodified copy of `movi-player@0.4.1` `dist/movi.wasm`. It statically
links FFmpeg build **63.1.102**, configured **without** `--enable-gpl`, therefore the
LGPL-2.1-or-later terms apply (not GPL).

```
FFmpeg — https://ffmpeg.org
Licensed under the GNU Lesser General Public License, version 2.1 or later
```

Because FFmpeg is statically linked here, LGPL §6 requires that recipients can relink
against a modified FFmpeg. To comply when you distribute this repository or serve these
files publicly, provide:

1. This NOTICE file and the LGPL-2.1 text
   (https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt), and
2. The corresponding source for the FFmpeg build used, plus the toolchain and
   `emconfigure`/`emmake` invocation needed to rebuild `movi.wasm`.

Upstream sources for both the wrapper and the FFmpeg fork:
- https://github.com/mrujjwalg/movi-player
- https://ffmpeg.org/download.html

If you only run this locally for yourself, none of the distribution obligations are
triggered — but do not delete this file, since it documents where the binaries came from
and how to rebuild them.

## 4. Not redistributed here

movi-player bundles `dashjs`, `hls.js` and `shaka-player` code inside `movi.js`
(Apache-2.0 / BSD-3-Clause); their notices are part of the upstream package. This
repository does not bundle those packages as separate files.
