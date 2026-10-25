# Journal - otix (Part 1)

> AI development session journal
> Started: 2026-10-21

---


## 2026-10-25 — 10-25-lan-tls (LAN HTTPS bootstrap)

- Private CA + 825d leaf instead of one self-signed cert: a SAN has to name the address
  clients type, so a self-signed cert dies on every LAN IP change *and* forces a re-trust.
  With a CA, re-issuing the leaf is invisible to devices.
- Static files moved into `assets/`; `tls/` sits beside it. `assets/` is an HTTP namespace,
  so a private key in there is downloadable — the script now fails if one appears.
- Trust page is served by dufs itself (`assets/trust/index.html`), so no file ever has to be
  moved between devices; only the CA install per device remains, and that cannot be automated
  from a web page.
- Gotcha that cost a round: dufs' `--assets` handler serves files only. `GET .../trust/`
  returns `500 Is a directory (os error 21)`; link `trust/index.html`.
- Verified with dufs 0.47.0 + headless Chrome: `isSecureContext` true and `VideoDecoder`
  defined over TLS on the LAN IP, `false`/`undefined` over plain HTTP on the same address.

## 2026-10-25 — 10-25-player-height (clipped player)

- Symptom: bottom control bar off-screen on a deep path. Cause: `calc(100vh - 3.1em)`
  assumed a one-row dufs header, but `.head` is `flex-wrap: wrap` and a long breadcrumb makes
  it 97px. Measured 47px of overflow = exactly the control bar.
- Fix is a flex chain body → .main → .editor-page. The `.main` level is the one everyone
  forgets: without it the player's inline `aspect-ratio` decides the height and you get a
  letterboxed box with dead space instead of a filled page.
- `100dvh` + `100vh` fallback for mobile toolbars; the error slot keeps its space and the
  player shrinks, so error text is never clipped either.
- "No yellow bar on https with an untrusted cert" is correct behaviour: isSecureContext
  follows the scheme, so WebCodecs works and only the browser's "Not secure" label remains.
  Documented in README + spec; it cannot be detected from JS.
