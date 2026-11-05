# PRD — Always-visible Trust link in the header

## Problem

`assets/trust/index.html` (how to install the server certificate on each platform) is only linked
from the certificate hint, and that hint mounts **only on the player page** and **only when the
certificate is untrusted** (`detectCertificateTrust()` → `untrusted`). A visitor who dismissed the
browser warning once, or who is on the directory page, has no in-app route back to the
instructions — they must remember the URL or retype it.

## Requirements

R1 — A link to `assets/trust/index.html` is present on **every** page (directory, text `?view`,
video `?view`, `?edit`), whether or not the certificate is trusted.

R2 — It sits in the top bar, next to dufs' own controls, without disturbing the existing ones.

R3 — It opens in a new tab (`target="_blank" rel="noopener"`), so the file list is not lost.

R4 — It must be reachable on a phone. The "Trust" label hides below 600 px; the icon stays.

R5 — Static markup in `index.html` using the `__ASSETS_PREFIX__` placeholder — no JS, no
`__dufs_v<version>__` literal, and no dependency on `DATA` (page state).

R6 — The link must point at `trust/index.html`, never `trust/` — dufs' assets handler returns
`500 Is a directory (os error 21)` for a directory URL.

## Placement decision, measured

`.toolbox-right` (the login/logout cluster) was the first choice and is wrong: at 390 px wide the
link lands at x≈474, past the right edge of the viewport, because the header overflows
horizontally on its own (246 px search field — upstream behaviour). Appending it to `.toolbox`
measured x≈44 (root) and x≈318 (three-level path) at 390 px — inside the viewport in both cases.

## Acceptance criteria

A1 — `.trust-link` exists on directory, text `?view` and video `?view` pages; `href` ends with
`trust/index.html` and returns 200.

A2 — `target="_blank"`, `rel="noopener"`, `title` present.

A3 — At 390 / 420 / 600 / 900 / 1440 px the link's box stays inside the viewport; label `block`
at ≥900, `none` at ≤600.

A4 — Player page: header height 49, player bottom == `innerHeight`, `scrollHeight - innerHeight
== 0` (the §6 layout contract still holds with the extra header child).

A5 — Icon colour follows the link colour (`fill: currentColor`): grey by default, accent on hover.

A6 — `movi.js` / `movi.wasm` sha256 unchanged; `bump-assets.sh` run; `node --check index.js` ok.
