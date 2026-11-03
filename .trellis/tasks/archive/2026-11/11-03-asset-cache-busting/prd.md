# PRD — Cache-bust the two mutable assets with their mtime

## Problem

dufs serves everything under `--assets` with a one-year immutable cache, and has no switch to
change it:

```
GET /                              -> Cache-Control: no-cache
GET /__dufs_v0.47.0__/index.js     -> Cache-Control: public, max-age=31536000, immutable
GET /__dufs_v0.47.0__/index.css    -> same
GET /__dufs_v0.47.0__/index.js?v=x -> 200, same bytes (dufs ignores the query string)
curl dufs --help | grep -i cache   -> no such option
```

Consequence, observed in practice: after deploying a new `index.js` to the NAS, every browser
that has visited before keeps running the old one for up to a year. The new features silently
do nothing (arrow-key seeking, the certificate hint), and nothing in the UI says why. The only
workaround today is a manual hard reload on every device — painful on a phone, and easy to
forget.

Because `index.html` is served `no-cache`, it is always fresh. That is the lever: give the two
mutable assets a changing URL, and the stale cache becomes unreachable.

## Requirements

R1 — `assets/index.html` requests `index.css` and `index.js` with a per-file version query:
`?v=<mtime>`, where `<mtime>` is the file's modification time in seconds.

R2 — Each file carries **its own** version, so editing only `index.js` does not invalidate a
cached `index.css`.

R3 — A committed script `bump-assets.sh` rewrites both versions in place and is idempotent. It
must work on both GNU and BSD/macOS userlands (no `sed -i` portability trap).

R4 — `movi.js`, `movi.wasm`, `favicon.ico` and everything under `trust/` stay **unversioned**:
they change only when syncing upstream, and their one-year cache is a feature (≈10 MB saved).

R5 — The prefix stays the `__ASSETS_PREFIX__` placeholder. Never hard-code `__dufs_v<version>__`.

R6 — The rule "run `./bump-assets.sh` whenever `index.css` or `index.js` changes" is written
into `AGENTS.md` so an agent reads it without knowing this task ever existed. It goes **after**
the `<!-- TRELLIS:END -->` marker, which a `trellis update` may overwrite.

R7 — Docs: README explains the mechanism and the deploy consequence; the spec gains the rule
plus the verification step.

## Out of scope

- Content-hash versions. `sha256sum | cut -c1-8` is the same effort and avoids false invalidation
  on `touch` / re-extract; recorded as a one-line alternative in the docs, not implemented.
- A pre-commit hook enforcing the bump (no hooks infrastructure in this repo).
- Any change to dufs itself (it has no cache-header option, and we do not patch the binary).

## Known trade-offs

- `mtime` changes without a content change (`touch`, re-extracting an archive). The cost is one
  unnecessary download of a ~38 KB file, and `tar` preserves mtimes so a normal deploy does not
  trigger it.
- Forgetting to run the script reproduces exactly today's bug. Mitigated by R6 + the spec
  checklist, not by tooling.

## Acceptance criteria

A1 — Served `index.html` contains `__ASSETS_PREFIX__index.css?v=<digits>` and
`__ASSETS_PREFIX__index.js?v=<digits>`, with different digits for the two files.

A2 — `bump-assets.sh` is idempotent: a second run produces byte-identical `index.html`.

A3 — `touch assets/index.js` then `./bump-assets.sh` changes only the `index.js` version.

A4 — Loading `?view` on a video works and the network log shows the css/js requests carrying
the `?v=` query; the player still mounts and plays.

A5 — Directory page, text `?view`, `?edit` and binary `?view` are unaffected.

A6 — `movi.js` / `movi.wasm` sha256 still match `UPSTREAM.md`; `node --check assets/index.js`
passes; `git status` shows only the intended files.
