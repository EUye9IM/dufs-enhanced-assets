# Design: detecting an untrusted certificate from JavaScript

## The constraint

No web API exposes certificate trust. `isSecureContext` is scheme-based (`https` → `true`),
`fetch()` on the same origin succeeds because the browser applies the click-through exception to
normal subresources, and `crypto.subtle` / `mediaDevices` behave identically either way.

## Measured discriminator: service worker registration

Same machine, same certificate, same page, two Chrome profiles (154.0.8037.57):

| Probe | Certificate untrusted (clicked "proceed") | Certificate trusted |
|---|---|---|
| `isSecureContext` | `true` | `true` |
| `fetch('/notes.txt')` | `200` | `200` |
| `crypto.subtle.digest()` | works | works |
| `navigator.serviceWorker.register('/sw.js')` | **`SecurityError: An SSL certificate error occurred when fetching the script.`** | **registered** |
| CDP `Security.certificateError` events | `ERR_CERT_AUTHORITY_INVALID` ×2 | none |

The trusted column was produced with `--ignore-certificate-errors-spki-list=<SPKI of our leaf>`,
i.e. the browser treats exactly this certificate as valid — the same state an installed CA
produces.

**Why it works**: the click-through exception is applied when fetching subresources, but the
service worker script is fetched through a path that does not honour certificate exceptions. So
registration is a same-origin, JS-readable, causally-correct probe of "is this cert trusted".

## Contract

```js
// assets/index.js
async function detectCertificateTrust(prefix)
//   "untrusted"  registration threw and the message mentions certificate/SSL
//   "trusted"    registration resolved
//   "insecure"   !window.isSecureContext (no service worker possible)
//   "unknown"    no serviceWorker API, or the failure was something else (404, CSP, …)
```

Only `"untrusted"` mounts a hint. Everything else is silent (R7). Matching on the message keeps
us honest: a missing/renamed `sw.js` yields a 404 message, not a certificate message, so a
stale deployment cannot produce a false accusation.

## Files

| File | Change |
|---|---|
| `assets/trust/probe-sw.js` | new, install handler only, no fetch handler, no cache, ~40 bytes |
| `assets/index.js` | `assetsPrefix()` helper; `detectCertificateTrust()`; drop the whole `!isSecureContext` block; mount the hint when `untrusted` |
| `assets/index.css` | `.movi-hint` reused; only its leading comment changes |
| `README.md` | "Why there is no warning on an untrusted https page" → "How the player notices an untrusted certificate" |
| `.trellis/spec/frontend/dufs-asset-pack.md` | §5 rewritten: secure-context gating → certificate-trust probe contract |

## Why a service worker file and not something cheaper

- `<img>` / `fetch` cross-origin: `no-cors` always resolves (opaque), `cors` failures are
  indistinguishable from offline. Needs a second listener. Rejected.
- `window.open` + polling: cross-origin, no information. Rejected.
- Certificate Transparency / timing: not measurable from a page. Rejected.

Registration is one request for a ~40-byte script, same origin, no second listener.

## Residue and lifecycle

The probe registers, reads the outcome, and calls `unregister()` — the answer is already known,
and leaving registrations behind under `__dufs_v<ver>__/trust/` would accumulate one stale
registration per dufs upgrade. Probing on every player page load (rather than caching in
`sessionStorage`) means the hint disappears on the next navigation after the user installs the
CA, which is the behaviour we want.

## Failure modes

| Situation | Result |
|---|---|
| Service worker API missing | `unknown` → silent |
| `probe-sw.js` 404 / MIME wrong | `unknown` → silent (message has no "certificate") |
| Browser blocks registration for another reason | `unknown` → silent |
| Certificate trusted but registration fails for a non-cert reason | `unknown` → silent (fail-safe) |
| Non-Chromium behaviour differs | worst case `unknown` → silent, never a false alarm |

## Hint placement

`.movi-hint` is absolutely positioned over the top of the player and `pointer-events: none`
except for the link, so it cannot swallow clicks on the control bar. Text is two sentences plus
the link, staying inside `max-width: min(90%, 46em)`.

## Rollback

Single commit: revert restores the previous `!isSecureContext` block; no data, config or server
change is involved.
