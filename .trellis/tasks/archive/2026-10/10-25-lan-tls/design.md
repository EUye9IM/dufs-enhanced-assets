# Design — LAN HTTPS bootstrap

## 1. Layout decision (resolves R2 + R3)

```
assets/                 ← the ONLY thing ever passed to --assets
  index.html  index.css  index.js  favicon.ico  movi.js  movi.wasm
  trust/
    index.html          ← committed trust page (the "how do I trust this" doc)
    ca.crt              ← generated + published (public cert only)
    dufs-ca.mobileconfig← generated + published (iOS profile)
scripts/
  gen-tls.sh            ← generates TLS material, publishes public half into assets/trust/
tls/                    ← generated, gitignored, mode 0600/0700 — NEVER served
  ca.crt  ca.key  dufs.crt  dufs.key
sync-movi.sh  README.md  UPSTREAM.md  NOTICE.md  LICENSE-*   ← repo root
```

Why a directory named `assets/` and not `dist/` or `web/`: dufs' own flag is `--assets`,
so `--assets ./assets` is self-documenting and impossible to confuse with the repo root.

`tls/` sits **next to** `assets/`, never inside it, so "serve the repo root by habit"
cannot leak the CA key through `/__dufs_v0.47.0__/`. Two structural guards on top of the
layout:

1. `gen-tls.sh` refuses an `--out-dir` that resolves inside `assets/`.
2. The script's `--verify` mode (also run at the end of a normal generation) fails if any
   file under `assets/` contains a PEM **private-key** header. Certificates are fine there —
   `assets/trust/ca.crt` is deliberately public — keys are not. It also catches the
   "symlinked tls/ into assets/" mistake.

Publishing rules, enforced by the script:

| File | Committed | Served | Secret |
|---|---|---|---|
| `assets/trust/index.html` | yes | yes | no |
| `assets/trust/ca.crt` | no (generated) | yes | **no** — public cert, safe to serve |
| `assets/trust/dufs-ca.mobileconfig` | no (generated) | yes | **no** — contains the cert only |
| `tls/ca.key`, `tls/dufs.key` | never | never | yes |

`.gitignore` covers `tls/` and the two generated files under `assets/trust/` (keep
`assets/trust/index.html` tracked). The repo still ships zero secrets, which is the explicit
answer to the "bake a default keypair into the project" idea: a committed private key is
public by definition, and a public private key means anyone who has read the repo can
impersonate the server to any device that trusts it.

Serving `ca.crt` does **not** weaken the "private CA, LAN only" position: it is a public
key. Anyone who downloads it can verify this server; nobody can impersonate it, because
`ca.key` never leaves `tls/`. "Private CA" refers to *not being in the OS/browser vendor
trust programs* — not to keeping the certificate itself hidden.

## 2. Trust model: private CA + short-lived leaf

Terminology used throughout: **private CA** = a root we mint ourselves on the server, at no
point submitted to any OS/browser vendor trust program — no ACME/Let's Encrypt, no public
CA, no Certificate Transparency logging, no OCSP/CRL infrastructure, no external network
dependency. It only ever exists so that *our own* devices can be told to trust *this one*
server. The leaf is signed by it and nothing else.

Single self-signed server certificate was rejected (PRD out-of-scope): its SAN has to name
the address clients type, so every LAN IP change would force a re-generate **and** a
re-trust on every device.

```
dufs.crt (leaf, CA:FALSE, SAN = IPs + hostnames)   ← re-issued whenever the IP changes
      └── signed by ──► ca.crt (CA:TRUE, 10y)      ← installed once per device, never changes
```

The CA is the only thing a human installs. Re-issuing the leaf is one command on the
server, invisible to clients.

| Material | Validity | Re-issue trigger |
|---|---|---|
| `ca.crt` / `ca.key` | 10 years (`--ca-days`) | only `--force-ca`, which invalidates every client's trust |
| `dufs.crt` | 825 days (`--leaf-days`) | IP/hostname change, expiry, `--force` |

825 days is deliberate: it is under Apple's former `/ 825`-day ceiling for the cases where a
CA ends up in a managed store, and re-issue after expiry needs no client action. Certificates
from a *user-installed* root are exempt from the 398-day rule on Apple platforms; if the CA is
later pushed into a managed/system store, re-run with `--leaf-days 397`.

Key/alg choices, and why they are constrained by dufs:

- **EC P-256** by default (smaller handshake, fine on any client from the last ~8 years);
  `--rsa` produces RSA-2048 for an old client that cannot do ECDSA.
- The key **must be PKCS#8** (`-----BEGIN PRIVATE KEY-----`). dufs loads the key through
  rustls, which in the versions dufs 0.47 targets parses PKCS#8 only — a PKCS#1
  (`BEGIN RSA PRIVATE KEY`) file is a runtime handshake failure, not a helpful error. The
  script writes PKCS#8 and asserts the header.
- The leaf **must carry a SAN**. Chrome has ignored CN since 58, and rustls/webpki requires
  either SAN or CN but will reject a name mismatch anyway.
- Certificate and key must be a pair; the script compares `x509 -pubkey` against
  `pkey -pubout` after generating (cheap, catches a half-finished previous run).

## 3. `scripts/gen-tls.sh` contract

```
scripts/gen-tls.sh [options]

  --host <name|ip>     extra SAN entry, repeatable
  --no-auto            disable auto-detected addresses (only --host + loopback)
  --out-dir <dir>      default: tls/
  --mobileconfig [f]   write an iOS/iPadOS CA profile (default: tls/dufs-ca.mobileconfig)
  --ca-days <n>        default 3650
  --leaf-days <n>      default 825
  --rsa                RSA-2048 instead of P-256
  --force              re-issue the leaf even if still valid
  --force-ca           regenerate the CA (every client must re-trust) — prompts first
  --verify             only run the sanity checks and exit
  -q | --quiet
```

Behaviour:

1. Preflight: `openssl` present; `--out-dir` not inside `assets/`; create dir 0700; keys 0600.
2. SAN set = explicit `--host` ∪ (unless `--no-auto`) loopback (`localhost`, `127.0.0.1`,
   `::1`) + `hostname` + `hostname -s` + `<hostname>.local` + IPv4s from
   `ip -4 -o addr` (fallback `hostname -I`). Dedupe, drop empty, classify IPv4 / IPv6 / DNS
   by regex, emit `IP:` / `DNS:` prefixes. Warn if the result contains only loopback.
3. CA: create if `ca.crt`/`ca.key` missing (`-x509`, `basicConstraints=critical,CA:TRUE`,
   `keyUsage=critical,keyCertSign,cRLSign`). Never touch an existing CA without `--force-ca`.
4. Leaf: skip when the existing leaf parses, verifies against `ca.crt`, still has ≥30 days
   left, and its SAN set already equals the requested set; otherwise re-issue. Always
   replace, never append.
5. Extensions: `basicConstraints=critical,CA:FALSE`, `keyUsage=critical,digitalSignature,
   keyEncipherment`, `extendedKeyUsage=serverAuth`, `subjectAltName=<set>`, `subjectKeyIdentifier`
   / `authorityKeyIdentifier`. Subject: `/CN=dufs-lan`.
6. Verify: pair match, `openssl verify -CAfile`, SAN echo, expiry date, PEM header check on
   the key, and the "no private key under `assets/`" scan.
7. Print exactly what to do next: the `dufs --tls-cert … --tls-key …` command with the
   detected IP filled in, and the per-platform trust one-liners (see §5). `-q` suppresses
   the prose, keeps the paths.

Idempotent by construction: re-running with an unchanged environment prints "leaf still
valid" and exits 0 with no file changes; changing the LAN IP re-issues only the leaf.

## 4. Trust bootstrap: no out-of-band file distribution

### 4.1 Two questions this has to settle first

*Can the keypair be generated in the frontend?* No, and the reasons are structural, not
policy:

1. dufs loads `--tls-key` from disk at startup. A key that lives in a browser tab cannot be
   loaded by the server, and there is no way for a page to push it there (dufs' upload
   writes into the share, and nothing can restart the process).
2. Even the *signing* half does not move: whoever signs the leaf holds a CA private key, and
   that CA must be the one installed in the client trust store. Generating it in a browser
   and then exporting it back to the server is a distribution problem plus a key that
   travelled over the very channel it is supposed to protect.
3. A web page cannot add anything to the OS/browser trust store. WebCrypto keypairs are for
   page-level crypto; they never enter the TLS stack, and no site-controlled opt-in exists.

*Can distribution be avoided?* Yes — that is what R6 is. The public material is served by
**the same dufs instance**, so the device never has to receive a file from anywhere else.

### 4.2 The flow (one interstitial, then never again)

> Verified against dufs 0.47.0: the `--assets` handler resolves **files only**. A
> trailing-slash URL for a directory inside the assets tree returns
> `500 Is a directory (os error 21)`. So the trust page is addressed as
> `.../trust/index.html`, never `.../trust/`.

```
phone: https://192.168.1.100:24601/          ← cert not trusted yet
   └─ warning page ─► "proceed" (once, this visit only)
        └─ index page shows the insecure-context banner
             └─ tap "How to fix" ─► /__dufs_v0.47.0__/trust/index.html
                  ├─ Download CA certificate   (iOS/Android: profile)
                  ├─ Install, per-platform steps inline
                  └─ reload ─► no warning, isSecureContext === true
```

Nothing is transferred between devices: the CA is fetched from the server the user is
already talking to. The one-time interstitial and the one-time trust install are the
irreducible cost — the interstitial because the certificate is not trusted yet, the install
because the OS owns the trust store.

### 4.3 First-visit authentication (TOFU)

A CA fetched over a channel that is not yet trusted is trust-on-first-use: an attacker on
path for that first visit could hand over their own CA. Mitigations, all cheap:

- `gen-tls.sh` prints `sha256 Fingerprint=` of `ca.crt` in its banner.
- `assets/trust/index.html` tells the operator to compare it against
  `openssl x509 -noout -fingerprint -sha256 -in assets/trust/ca.crt` on the server.
- The realistic threat model is a home LAN, so this is documented, not automated.

### 4.4 iPhone profile (generated into `assets/trust/`)

iOS/iPadOS cannot import a bare `.crt` into the trust store — only a configuration
profile. The script emits a minimal `com.apple.security.root` profile:

- `PayloadType=Configuration`, one inner payload `PayloadType=com.apple.security.root`,
  `PayloadContent` = base64 of `openssl x509 -outform der`, `PayloadCertificateFileName=ca.crt`.
- Random UUIDs from `/proc/sys/kernel/random/uuid`, `PayloadVersion=1`, no signing
  (unsigned = the OS asks the user to confirm installation, and warns that the profile is
  unsigned — expected, say so on the page).
- Non-secret: it contains the CA **certificate** only. Safe to AirDrop/host/serve.
- iOS resolves `.mobileconfig` by extension even when dufs serves it with an unknown MIME
  type, so serving it as a plain asset works — but the page must say "Download → Allow →
  close → Settings", not expect an automatic prompt.

Still two manual steps on device (install profile → Settings › General › About › Certificate
Trust Settings › enable full trust). That is an OS constraint, not something we can remove.

## 5. Docs changes

| File | Change |
|---|---|
| `README.md` | Deploy section uses `--assets ./assets`; "Fix 1" becomes `./scripts/gen-tls.sh` + the printed command; new trust matrix subsection with the "proceed anyway is not trust" callout; Layout tree updated; `tls/` documented as generated + gitignored. |
| `UPSTREAM.md` | Local-diff table paths → `assets/index.js` etc.; add `scripts/gen-tls.sh` as a local-only addition; sync procedure emits into `assets/`. |
| `sync-movi.sh` | Write into `assets/`, sanity-check the destination exists. |
| `.trellis/spec/frontend/dufs-asset-pack.md` | `--assets <this-repo>/assets`; new hard rule: *`assets/` is an HTTP namespace — certificates and the trust page may live there, private keys never*; note the secure-context/TLS rule now points at the script. |
| `assets/trust/index.html` | New committed page: what/why, download links (`ca.crt`, `.mobileconfig`), per-platform steps, fingerprint check, the "proceed is not trust" callout. Relative links only, so nothing hard-codes `__dufs_v*__`. Addressed as `trust/index.html` — dufs cannot serve a directory URL under `--assets`. |
| `assets/index.js` | Insecure-context hint becomes a link to the trust page, URL built from the assets-prefix meta tag + `trust/index.html`. |
| `.gitignore` | `tls/`, `assets/trust/ca.crt`, `assets/trust/*.mobileconfig` |

## 6. Tradeoffs / risks

| Decision | Cost |
|---|---|
| Private CA instead of one self-signed cert | One extra file to distribute (`ca.crt` / `.mobileconfig`), one extra flag pair in the docs — bought by "IP changes never require a client to act". |
| CA trusted once per device | Unavoidable. Trust stores are the OS's, not the browser's; no site-side opt-in exists. |
| `assets/` subdirectory | Breaking change for anyone with an existing `--assets <repo-root>` command. Mitigated by README/UPSTREAM being updated in the same commit and by the 404 being loud. |
| Leaf re-issue every 825 days | One command + restart. Printed expiry date makes it discoverable. |
| Script is bash + openssl | Same dependency class as the existing `sync-movi.sh`; Linux/macOS only. Windows operators keep the manual openssl path in README. |
| Trust material served from the same origin | First visit is TOFU and needs one interstitial click; documented with the fingerprint check. Strictly better than out-of-band copying, which is also TOFU with more steps. |
| Trust page lives under the versioned assets prefix | Its URL changes on every dufs upgrade (`__dufs_v0.47.0__` → …), so a phone bookmark to it breaks once per upgrade. Accepted: the in-app hint always links to the current prefix, and the README pins the pattern rather than a URL. |
| One install per device remains | Cannot be automated from the web. A publicly-trusted name would remove it entirely, but that is explicitly out of scope (LAN-only, no external dependency) — see PRD out-of-scope. |

## 7. Rollout / rollback

- Rollout: single commit (layout move + script + docs). Nothing is deployed by CI; the
  operator's `--assets` path change is the only action item, called out in the commit body.
- Existing plain-HTTP deployments keep working if `--assets` is repointed; they lose nothing
  but the TLS work is opt-in.
- Rollback: `git revert` the commit and `git mv assets/* .` — no state, no migrations,
  `tls/` is untracked either way.

## 8. Verification plan

Beyond the PRD acceptance table (A1–A10), the run that actually matters is the hardware one:
serve a 1080p H.264 MKV over `https://<lan-ip>` on a trusted client and confirm
`isSecureContext === true`, `typeof VideoDecoder === "function"`, and that playback stays
realtime (previous measurement: 95 % realtime with WebCodecs vs 57 % without). If the cert
is generated but not trusted, the result must be identical to plain HTTP — that is the
regression that proves the whole task exists for a reason.
