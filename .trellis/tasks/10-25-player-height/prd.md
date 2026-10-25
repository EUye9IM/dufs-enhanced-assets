# PRD — Fix clipped player under a wrapped dufs header

## Problem

On a video `?view` page, the bottom of the player (its control bar: play, time, fullscreen)
is pushed off-screen whenever the dufs header wraps to more than one row.

Reproduced with the reporter's own path shape
(`/dl/Cyberpunk.Edgerunners.S02.1080p.NF.WEB-DL.DUAL.DDP5.1.H.264-VARYG/Cyberpunk.Edgerunners.S02E01….mkv?view`):

| Measurement | Short path (`/big.mp4?view`) | Long path (reporter's) |
|---|---|---|
| `innerHeight` | 757 | 757 |
| `.head` height | 49 | **97** (breadcrumb wraps: `.head` is `flex-wrap: wrap`) |
| `.editor-page` height | 707 | 707 |
| `.movi-player` top → bottom | 49 → 757 | 97 → **804** |
| `body.scrollHeight` | 757 | **804** (47 px overflow) |

Cause: `assets/index.css` sets

```css
body.has-movi-player .editor-page { height: calc(100vh - 3.1em); }
```

i.e. it assumes the header is exactly `3.1em` (≈49 px). Any wrapped row breaks the constant,
and the stale `body.has-movi-player { overflow: hidden }` prevents scrolling to the hidden
part.

## Requirements

R1 — The player fills the space below the header **whatever the header's height is**: one row,
two rows, three rows (narrow window), and after a window resize without reload.

R2 — No magic number tied to the header. The fix must not encode `3.1em` or any other guess
about dufs' chrome.

R3 — Scrolling stays disabled on the player page (the page is meant to be one screen), and no
part of the player may be clipped.

R4 — Element fullscreen keeps working: the player must still fill the whole screen.

R5 — Unchanged behaviour for every non-player page (directory listing, text editor, other
binary files): the rule must only apply to `body.has-movi-player`.

R6 — Mobile: the layout must survive a dynamic browser toolbar (iOS/Android) rather than
assuming `100vh` is stable.

R7 — Docs must state that an *untrusted* https certificate does **not** hide the
insecure-context hint, because `isSecureContext` follows the scheme: on `https://<lan-ip>`
with a certificate the browser does not trust, WebCodecs is available, the hint is correctly
absent, and only the browser's "Not secure" label remains (removable only by installing the
CA).

## Acceptance criteria

| # | Check |
|---|---|
| A1 | Long wrapped path: `body.scrollHeight === innerHeight`, `.movi-player` bottom edge `<= innerHeight` (±1 px), control bar fully inside the viewport. |
| A2 | Short path (`/big.mp4?view`) behaves exactly as before (bottom edge == viewport bottom). |
| A3 | Narrow window (header wraps to 3 rows): still no overflow, controls visible. |
| A4 | Resize the window after load (wider → narrower → wider): player keeps fitting, no reload. |
| A5 | Element fullscreen: player rect == viewport rect. |
| A6 | Directory listing / text `?view` / non-video binary page: layout unchanged, page still scrolls normally. |
| A7 | Error path (`?view` on undecodable video) still shows the message and download link, unclipped. |
| A8 | README explains hint vs. browser "Not secure" (§R7). |

## Out of scope

- Any change to dufs' own CSS beyond the `body.has-movi-player` scope.
- Detecting certificate trust from JavaScript (not possible).
- The `24601` default port shown in the script banner (separate concern).
