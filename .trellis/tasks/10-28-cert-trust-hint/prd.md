# Warn when the server certificate is not trusted

## Problem

The player used to warn when `window.isSecureContext` was false. That branch is dead in this
deployment: dufs runs with `--tls-cert`, so every page is `https`, and `isSecureContext` is
`true` even when the client merely clicked through the certificate warning. Result:

- a guest who taps "proceed" lands on a page that looks perfectly fine,
- the connection is **not authenticated** — anyone on the LAN can impersonate the server,
- nothing in the UI says so, and the trust page is only reachable if someone remembers the URL.

## Requirement

Detect, on the player page, that the browser does **not** trust the certificate, and offer the
trust page. Do not warn in any other case.

| # | Requirement |
|---|---|
| R1 | The hint appears when the certificate is not trusted (user clicked through the interstitial). |
| R2 | The hint does not appear when the certificate is trusted (CA installed), or when trust cannot be determined. |
| R3 | The old `!isSecureContext` hint is removed — code and copy — with no explanatory comment left behind. |
| R4 | The hint is mounted on the player page only, over the player (reusing `.movi-hint`), and must not block the player controls or the control bar. |
| R5 | The hint links to the trust page and states that playback is unaffected but the server can be impersonated. |
| R6 | No new port, service, or server-side change. Works on a plain dufs `--tls-cert` deployment. |
| R7 | Detection failure is silent: no false "your connection is unsafe" for users who are fine. |
| R8 | README and the frontend spec describe the new rule; nothing documents the removed behaviour. |

## Acceptance criteria

- A1 Untrusted certificate (Chrome, clicked through) → hint visible on `/file.mp4?view`, link
  points at `<prefix>trust/index.html`, and the trust page opens.
- A2 Trusted certificate (same browser, CA accepted) → no hint.
- A3 Click-through → the video still plays (hardware decoding works; the hint is about
  authentication, not capabilities).
- A4 The hint does not overlap the control bar, and the player still fills the viewport
  (`player.bottom === innerHeight`) in the long-path and narrow-window cases.
- A5 Directory page, editor page and plain `http` all show no hint.
- A6 `movi.js` / `movi.wasm` byte-identical; `node --check assets/index.js` passes.

## Out of scope

- Detecting certificate **hostname** mismatches, revocation, or expiry separately.
- Warning about anything on non-player pages.
- Browsers without service worker support (Safari < 11.1, old Firefox): treated as "unknown",
  therefore silent.
- The `movi` `mov_text` subtitle backlog (separate task `10-28-movi-movtext-subs`).
