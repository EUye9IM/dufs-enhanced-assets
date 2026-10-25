# Implement — LAN HTTPS bootstrap

Order matters: move files first, so every later edit lands in its final path.

## 0. Pre-flight

- [ ] `git switch -c feat/lan-tls` (or commit on main — repo currently commits on main)
- [ ] `node --check index.js` before and after the move, same result (baseline)
- [ ] Record baseline sizes: `wc -c index.js index.css index.html movi.js movi.wasm`

## 1. Layout move (R3)

- [ ] `mkdir assets && git mv index.html index.css index.js favicon.ico movi.js movi.wasm assets/`
- [ ] `assets/` contains exactly 6 files: `ls assets`
- [ ] Hooks/readers of the old paths updated:
      `grep -rn "index\.\(js\|css\|html\)\|movi\.\(js\|wasm\)\|favicon" --include=*.md --include=*.sh .`
      → `README.md`, `UPSTREAM.md`, `sync-movi.sh`, `.trellis/spec/frontend/dufs-asset-pack.md`
- [ ] `sync-movi.sh`: destination becomes `$REPO_DIR/assets/`; fail if `assets/` is missing
- [ ] `mkdir -p assets/trust` (page is committed, generated material is not)
- [ ] `.gitignore`: `tls/`, `assets/trust/ca.crt`, `assets/trust/*.mobileconfig`

## 2. `scripts/gen-tls.sh` (R1, R2, R4)

Follow design §3. Structure:

- [ ] arg parsing (`--host`, `--no-auto`, `--out-dir`, `--mobileconfig`, `--ca-days`,
      `--leaf-days`, `--rsa`, `--force`, `--force-ca`, `--verify`, `-q`)
- [ ] `fail()` helper writing to stderr with exit 1; `set -euo pipefail`
- [ ] preflight: `openssl` in PATH, out-dir not inside `assets/`, `mkdir -p && chmod 700`,
      keys `chmod 600`
- [ ] SAN collection + dedupe + `IP:`/`DNS:` classification; warn on loopback-only
- [ ] CA create-if-missing; `--force-ca` requires an interactive `yes` and warns that every
      device must re-trust
- [ ] leaf create/reuse decision (valid ≥30d + CA verify + SAN set equality)
- [ ] extension file + `openssl req -x509`/`openssl x509 -req -CA`; PKCS#8 key check
- [ ] verify block: pair match, `openssl verify`, SAN echo, `notAfter`, `--verify` mode,
      and the `assets/` private-key scan
- [ ] `--mobileconfig`: outer + `com.apple.security.root` payload, base64 DER, UUIDs
- [ ] publish step: copy `ca.crt` → `assets/trust/ca.crt` and the profile →
      `assets/trust/dufs-ca.mobileconfig` (`--no-publish` to skip); **never** copy a key,
      and abort if the publish target is not the expected `assets/trust/`
- [ ] fingerprint line in the banner (`openssl x509 -noout -fingerprint -sha256`), same
      value the trust page tells the user to verify
- [ ] final banner: dufs command (with detected address), trust-page URL, trust one-liners
- [ ] `chmod +x`
- [ ] `bash -n scripts/gen-tls.sh` and (if available) `shellcheck scripts/gen-tls.sh`

## 3. Docs (R4, R5)

- [ ] `README.md`
  - [ ] Deploy commands → `--assets ./assets`
  - [ ] "Fix 1 — serve dufs over HTTPS" → `./scripts/gen-tls.sh`, drop the handwritten
        openssl one-liner, keep the dufs TLS invocation
  - [ ] Trust table: Linux / macOS / Windows / Android / iOS / Firefox, each one line
  - [ ] Explicit callout: *"Advanced → Proceed" is a per-session bypass, not trust; it
        leaves the origin marked insecure and is not a supported setup*
  - [ ] Layout tree + `tls/` generated/ignored note
  - [ ] Known issues: replace the manual-openssl phrasing with the script
- [ ] `UPSTREAM.md`: diff table paths → `assets/*`, add `scripts/gen-tls.sh`, sync procedure
      writes into `assets/`
- [ ] `assets/trust/index.html` (new, committed): plain HTML+CSS, no framework
  - [ ] what/why in two sentences (`!isSecureContext` → software decode → stutter)
  - [ ] download buttons for `ca.crt` and `dufs-ca.mobileconfig`, relative paths
  - [ ] per-platform steps: Linux / macOS / Windows / Android / iOS / Firefox
  - [ ] fingerprint verification snippet
  - [ ] "Advanced → Proceed is not trust" callout; unsigned-profile warning for iOS
  - [ ] link back to the file browser (`../` is the assets prefix root, **not** the share) —
        use the assets-prefix meta-less approach: a relative `../` from `trust/`; verify
        the rendered result rather than assuming
- [ ] `.trellis/spec/frontend/dufs-asset-pack.md`: `--assets <repo>/assets`; new hard rule
      "`assets/` is an HTTP namespace — certs/page yes, private keys never"; secure-context
      rule points at the script
- [ ] `assets/index.js`: insecure-context hint becomes an anchor to
      `<meta assets-prefix> + "trust/index.html"` (dufs 500s on a directory URL under
      `--assets` — verified), same text otherwise (keep it one sentence)

## 4. Validation

Run all of these; paste failures, do not skip.

```bash
bash -n scripts/gen-tls.sh
node --check assets/index.js

# A1/A2/A3
./scripts/gen-tls.sh
openssl x509 -in tls/dufs.crt -noout -text | grep -A2 "Subject Alternative Name"
openssl x509 -in tls/dufs.crt -noout -ext basicConstraints,extendedKeyUsage
openssl verify -CAfile tls/ca.crt tls/dufs.crt

# A4: leaf re-issue on a changed SAN, CA untouched
sha256sum tls/ca.crt > /tmp/ca.before
./scripts/gen-tls.sh --host 10.99.99.99
sha256sum -c /tmp/ca.before
openssl x509 -in tls/dufs.crt -noout -ext subjectAltName | grep 10.99.99.99

# A5: idempotency
sha256sum tls/* > /tmp/tls.before; ./scripts/gen-tls.sh; sha256sum -c /tmp/tls.before

# A6/A7
find assets -type f | sort                   # 6 served files + trust/index.html + published pair
git status --short                           # tls/ and the generated pair are ignored
! grep -rl "PRIVATE KEY" assets/             # must find nothing (certs are allowed)

# A11/A13: trust page + published material + fingerprint
./scripts/gen-tls.sh
ls -l assets/trust/
openssl x509 -in assets/trust/ca.crt -noout -fingerprint -sha256
#   must equal the banner's line and the value the page tells the user to verify
curl -sS --cacert tls/ca.crt -o /dev/null -w '%{http_code}\n' \
  https://localhost:24601/__dufs_v0.47.0__/trust/index.html
curl -sS --cacert tls/ca.crt -o /dev/null -w '%{http_code}\n' \
  https://localhost:24601/__dufs_v0.47.0__/trust/ca.crt
curl -sS --cacert tls/ca.crt -o /dev/null -w '%{http_code}\n' \
  https://localhost:24601/__dufs_v0.47.0__/trust/dufs-ca.mobileconfig
# A12: on the plain-HTTP server, the ?view hint's link must point at .../trust/ and 200

# A8: TLS serve + secure context
dufs /tmp/dufs-fixtures --assets ./assets --tls-cert tls/dufs.crt --tls-key tls/dufs.key \
  --bind 0.0.0.0 --port 24601
curl -sSI --cacert tls/ca.crt https://localhost:24601/ | head -3
curl -sS --cacert tls/ca.crt -o /dev/null -w '%{http_code} %{content_type}\n' \
  https://localhost:24601/__dufs_v0.47.0__/movi.wasm
# browser (trusted client): isSecureContext === true && typeof VideoDecoder === "function"

# A9: plain HTTP unchanged
dufs /tmp/dufs-fixtures --assets ./assets --bind 127.0.0.1 --port 24602
#   - directory listing renders, ▶ appears on video rows only
#   - ?view on a video shows the insecure-context hint

# A10
grep -rn -- "--assets" README.md UPSTREAM.md .trellis/spec | grep -v "assets/\|\./assets\|<repo>/assets"
```

- [ ] `dufs --help | grep tls` confirms flag names before documenting them
- [ ] `git diff --stat` shows no unintended edits to `assets/movi.js` / `assets/movi.wasm`
      (`git diff --exit-code -- assets/movi.js assets/movi.wasm` — must be clean)

## 5. Commit

- [ ] Single commit: `feat: generate LAN TLS material instead of documenting openssl`
- [ ] Body covers: assets/ move + why (servable-namespace isolation), CA-vs-self-signed
      rationale, IP-change behaviour, the trust-is-manual reality, and the breaking
      `--assets` path change
- [ ] Archive the task after spec update; update journal

## 6. Review gates

| Gate | Blocking |
|---|---|
| No private key reachable under `assets/` | yes |
| Trust page reachable over HTTPS with both downloads returning 200 | yes |
| Banner fingerprint == published `ca.crt` fingerprint | yes |
| `openssl verify` green + SAN contains a non-loopback address | yes |
| Re-run is a no-op / CA byte-identical | yes |
| Docs contain no `--assets <repo-root>` remnant | yes |
| Hardware-decode measurement (A8 browser step) | needs the operator's devices — record the result in the commit body or the journal, do not fake it |
