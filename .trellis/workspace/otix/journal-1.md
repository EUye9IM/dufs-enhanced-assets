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

## 2026-10-28 — 10-28-cert-trust-hint

- `isSecureContext` cannot answer "is this certificate trusted" — it only looks at the scheme.
  On a TLS-only dufs the old hint was dead code, so a guest who clicked through the interstitial
  was on an unauthenticated connection with no warning at all.
- The discriminator that works: register a service worker. Its script fetch does not inherit the
  click-through exception, so it fails with "An SSL certificate error occurred" precisely when
  the cert is untrusted. Verified both directions on one machine (untrusted profile vs
  `--ignore-certificate-errors-spki-list=<leaf SPKI>` as the "CA installed" stand-in).
- Fail safe: match the error message, not the failure. A 404 probe file must land on "unknown" →
  silent; tested by renaming the file away on the trusted profile.
- Rejected: cross-origin probes (`no-cors` always resolves opaque), a second listener, CT logs.
- Left `movi`'s `mov_text` gap as backlog task 10-28-movi-movtext-subs with the full evidence.

## 2026-10-29 — 10-29-player-seek-controls

- "Does the player support ←/→ seeking and swipe-to-seek?" — yes, all of it is in
  `movi.js`, gated behind the `fastseek` attribute, and **absent attribute means all three
  channels off**. That was our state, so arrow keys were dead on the player page.
- `fastseek="keys gestures"`: `←`/`→` = ±10 s with 1 s chaining, `Ctrl`/`Cmd`+arrow = ±1 frame,
  horizontal drag across the picture = `dx / width × 90` s with the target time in the OSD,
  double-tap left/right = ∓10 s. `buttons` left off so the phone control bar keeps its width.
- Trap worth remembering: `fastseek=""` (empty) means **all three**, not none.
- Trap worth remembering: keys only fire with focus on the host element; movi self-focuses on
  `pointerdown` inside, so "click once, then arrows" is the contract. No autofocus on mount.
- The progress bar's click/drag is a separate `mousedown`/`touchstart` path and never depended
  on `fastseek` — so touch-drag seeking already worked before this change.
- Bonus finding while debugging an unrelated report: the same show ships E03 as H.264 and E04
  as HEVC, which is why one Windows box software-decoded it; and Chrome falls back silently
  (`videoDecoder.hardwareUnavailable`) — logged in memory, still an open UX gap.
