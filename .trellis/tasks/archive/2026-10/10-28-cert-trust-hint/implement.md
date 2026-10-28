# Implement: certificate-trust hint

## Checklist

1. **`assets/trust/probe-sw.js`** — new file:
   ```js
   self.addEventListener("install", () => self.skipWaiting());
   ```
   Verify dufs serves it as JavaScript: `curl -sI .../trust/probe-sw.js | grep content-type`.

2. **`assets/index.js`**
   - [ ] Add `assetsPrefix()` (reads `meta[name="dufs-assets-prefix"]`), use it in `loadMovi()`
         and in the new hint code (removes two copies of the same 2 lines).
   - [ ] Add `detectCertificateTrust(prefix)` exactly as specified in `design.md`.
   - [ ] Delete the whole `if (!window.isSecureContext) { … }` block *and its comment block* from
         `mountVideoPlayer()`. No leftover explanation (R3).
   - [ ] After `document.body.classList.add("has-movi-player")`, kick off the probe without
         awaiting it; on `"untrusted"` insert the hint after the player and append
         `trust/index.html` link built from the same prefix.
   - [ ] `detectCertificateTrust` unregisters the probe registration on success.

3. **`assets/index.css`** — replace the `/* Shown only on insecure origins, where WebCodecs is
   unavailable. */` comment above `.movi-hint`. No rule changes expected.

4. **`README.md`** — rewrite the section added in `147d8e9` (`#### Why there is no warning on an
   untrusted https page`) into a description of the probe; delete the `!isSecureContext`
   sentence. Mention the Safari/unknown caveat.

5. **`.trellis/spec/frontend/dufs-asset-pack.md` §5** — replace the secure-context gating rules
   with the probe contract (enum, fail-safe to `unknown`, no second listener, `probe-sw.js`
   presence is load-bearing). Keep the "`isSecureContext` cannot see certificates" fact as the
   rationale for why the probe exists.

## Verification

Environment: dufs 0.47.0 with `tls/` from `./scripts/gen-tls.sh`, fixtures dir with a video.

```bash
# two listeners are only needed for the experiment, not for the feature
/tmp/dufs /tmp/dufs-fixtures --assets ./assets --tls-cert tls/dufs.crt --tls-key tls/dufs.key --bind 0.0.0.0 --port 24601 &
```

Chrome A (untrusted, exercises the click-through path):

```bash
google-chrome-stable --headless=new --remote-debugging-port=9224 --user-data-dir=/tmp/cr-cert ...
# CDP: Security.enable + Security.setOverrideCertificateErrors(true) + handleCertificateError(continue)
```

Chrome B (trusted): add `--ignore-certificate-errors-spki-list=$(openssl x509 -in tls/dufs.crt -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)`.

| Check | Expect |
|---|---|
| A1 untrusted, `/big.mp4?view` | `.movi-hint` present, text mentions certificate, `a[href]` ends `trust/index.html` |
| A2 trusted, same URL | `.movi-hint` absent |
| A3 untrusted | video plays (`isSecureContext === true`, no error slot) |
| A4 both | `player.bottom === innerHeight`, hint rect above the control bar band |
| A5 untrusted, `/` and `/notes.txt?view` | no hint; plain `http://<ip>:<port>` player page also no hint |
| A6 | `node --check assets/index.js`, `sha256sum assets/movi.js assets/movi.wasm` unchanged |

Also confirm the probe leaves nothing behind: `navigator.serviceWorker.getRegistrations()` → `[]`.

## Gates

- Review gate: PRD + design + this file before `task.py start`.
- After implementation: full matrix above, then spec update, then a single commit.
