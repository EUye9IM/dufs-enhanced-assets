# PRD — LAN HTTPS bootstrap

## Background

`movi-player` needs WebCodecs for hardware decoding, and WebCodecs is only exposed in a
secure context. On `http://<lan-ip>:24601` the player silently falls back to ffmpeg-wasm
software decoding on the main thread and drops from 24 fps to ~6 fps (measured, see
README). The previous change only *warned* about this. Nothing in the repo makes it
practical to get to HTTPS on a home LAN.

Making it practical means: a one-command way to mint TLS material that (a) matches the
address clients actually type, and (b) only has to be trusted once per device, even when
the LAN IP changes.

## Target scenario

**Home LAN, devices the operator owns.** Primary client is a phone/tablet/desktop on a
flat home network reaching a NAS/PC running dufs. Not for external users, not for
strangers, no public exposure.

## Requirements

### R1 — Generated TLS material, no committed secrets

- A script generates the TLS material locally. The repository contains **no** private
  key, no generated certificate.
- The material must cover the addresses clients actually use: the LAN IP, the hostname,
  `localhost`, and `127.0.0.1` — with a SAN, not just a CN.
- Trusting the setup must survive a LAN IP change: re-running the script must re-issue the
  server certificate **without** requiring any client to re-trust anything.
- Re-running the script must be safe and idempotent (does not silently replace the
  long-lived trust anchor).

### R2 — Nothing secret is servable

dufs serves every file under `--assets` over HTTP under `/__dufs_v<ver>__/`. TLS material
(and CA private key in particular) must be structurally unable to end up in that
namespace, even if the operator points `--assets` at the repository root by mistake or by
habit from the previous layout.

### R3 — Assets live in a subdirectory

- The files dufs serves (`index.html`, `index.js`, `index.css`, `favicon.ico`, `movi.js`,
  `movi.wasm`) live in a single subdirectory that is the only thing ever passed to
  `--assets`.
- Repo-level tooling (`sync-movi.sh`, the new script, docs, licences) lives outside it.
- All documentation paths and commands are updated to the new layout; no stale
  `--assets <repo-root>` instructions remain.

### R4 — Trust instructions that are actually correct

- Docs state plainly that browser "proceed anyway" is not trust and is not a supported
  path.
- One-time, per-device, per-platform trust instructions: Linux, macOS, Windows, Android,
  iOS/iPadOS, Firefox (separate store).
- iOS is the awkward one: a CA can only be installed as a `.mobileconfig` profile and then
  has to be enabled manually in Certificate Trust Settings. The script should produce that
  profile so the phone flow is two taps, not a certificate-assembly exercise.

### R6 — Self-hosted trust bootstrap (no out-of-band file distribution)

The CA certificate and the iOS profile must be downloadable **from dufs itself**, so that
trusting a device never requires moving a file onto it by USB / AirDrop / chat.

- A committed, static trust page (`assets/trust/index.html`) explains the problem, links to
  the CA certificate and the `.mobileconfig`, and gives the per-platform steps.
- The generated public material (CA **certificate** only, plus the profile) is published
  into that same served directory by the script. Never the CA key.
- The in-app insecure-context hint links to that page instead of only describing the
  problem.
- Consequence accepted and documented: reaching the trust page for the first time goes
  through the browser's certificate warning (trust-on-first-use), so the operator must be
  able to verify the CA fingerprint out-of-band — the script prints it, the page shows it.

### R5 — No new hard dependency for existing use

- Plain HTTP (no TLS flags) keeps working exactly as today, including the in-page
  `!isSecureContext` warning.
- No `package.json`, no bundler, no new runtime dependency beyond `openssl` (and standard
  shell tools) plus what the docs require.

## Acceptance criteria

| # | Check |
|---|---|
| A1 | Fresh clone: `./scripts/gen-tls.sh` produces `tls/ca.crt`, `tls/ca.key`, `tls/dufs.crt`, `tls/dufs.key` and prints the exact `dufs --tls-cert/--tls-key` command + trust steps. |
| A2 | `openssl x509 -in tls/dufs.crt -noout -text` shows a SAN containing at least the machine's LAN IP, its hostname, `localhost`, `127.0.0.1`; `basicConstraints` is `CA:FALSE`; `extendedKeyUsage` includes `TLS Web Server Authentication`. |
| A3 | `openssl verify -CAfile tls/ca.crt tls/dufs.crt` → OK. |
| A4 | Re-running the script with a new/changed IP re-issues the leaf and leaves `tls/ca.crt` byte-identical (compare sha256 before/after); the old leaf is replaced, not appended. |
| A5 | A second run in the same conditions does not delete the CA and does not fail. |
| A6 | `git status` after generating is clean apart from the intentional source changes — `tls/` is ignored. |
| A7 | `assets/` contains the six served files plus `assets/trust/` (page + published public material); no file under `assets/` matches a PEM private-key header. |
| A11 | After generation, `https://<lan-ip>:24601/__dufs_v0.47.0__/trust/index.html` serves the trust page, and the CA certificate + `.mobileconfig` it links to resolve to 200 with the right content type. Both are reachable **without** touching the filesystem on the client. |
| A12 | The insecure-context hint on a video view page contains a working link to that trust page (built from the assets-prefix meta tag, not hard-coded). |
| A13 | The trust page and the script banner print the same CA SHA-256 fingerprint, so a first visit can be verified against the server console. |
| A8 | `dufs <dir> --assets ./assets --tls-cert tls/dufs.crt --tls-key tls/dufs.key --bind 0.0.0.0 --port 24601`, then from a trusted client: page loads over `https://`, console shows `isSecureContext === true` and `typeof VideoDecoder === "function"`, `GET /__dufs_v0.47.0__/movi.wasm` → 200 `application/wasm`. |
| A9 | Same server without TLS flags still loads over `http://` and still shows the insecure-context hint on a video view page. |
| A10 | README/UPSTREAM/spec contain no remaining reference to the old repo-root-as-`--assets` layout. |

## Out of scope

- **Publicly-trusted names of any kind** — no Let's Encrypt / ACME, no overlay network's
  `cert` command, no Cloudflare Tunnel, no reverse proxy, no public domain. This deployment
  is LAN-only by decision: one private CA, no external dependency, no internet reachability
  requirement. (The alternatives exist and are fine; they are simply not this project's job.)
- Reverse proxy / Caddy / real public certificates.
- Automatic trust installation on clients (no MDM, no `sudo` automation, no
  `--unsafely-treat-insecure-origin-as-secure` helper).
- Not shipping a default/committed keypair — explicitly rejected: a public private key
  lets anyone impersonate the server.
- Generating the server keypair in the browser. A page cannot hand a key to the TLS stack of
  a server it does not control, and a browser-generated key cannot be loaded by dufs; only
  the *public* material can be served from the page (see R6).
- Automating the OS trust store from a web page — no such API exists by design.
- Changing dufs itself.
