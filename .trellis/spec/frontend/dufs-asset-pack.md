# dufs Asset Pack Conventions

> Scope: everything in this repository. This project is **not** a web app — it is a
> replaceable static asset pack for [dufs](https://github.com/sigoden/dufs), mounted at
> runtime with `dufs --assets <this-repo>/assets`. These rules are the ones that will
> actually break the deployment if ignored.

---

## 1. Hard constraints

| Rule | Why |
|---|---|
| Never modify dufs Rust source | The whole value of this repo is that upgrading dufs means swapping a binary, not rebasing a fork. |
| No build step: no `package.json`, no `node_modules`, no bundler, no TypeScript | dufs loads `index.html` / `index.js` / `index.css` verbatim. A build step would also break `git archive` / tarball deployment. |
| Third-party libraries must be a `*.global.js` IIFE | There is no module loader. `import` / `require` builds cannot be used. |
| Never hand-edit `assets/movi.js` / `assets/movi.wasm` | They must stay byte-identical to the upstream npm dist so a version bump is a plain diff. Use `sync-movi.sh`. |
| Never hard-code the asset URL prefix | See §2. |
| **Nothing private under `assets/`** | That directory is an HTTP namespace: every file in it is served under `/__dufs_v<ver>__/`. Certificates and the trust page are fine there (public keys); private keys, dumps, notes never are. `tls/` sits *next to* `assets/`, not inside it, and `scripts/gen-tls.sh` fails if a PEM private key appears under `assets/`. |
| Only `assets/` is ever passed to `--assets` | Everything else (`scripts/`, `tls/`, docs, licences) must stay unservable by construction, not by discipline. |

## 2. Asset URL prefix (the #1 source of 404s)

dufs serves the `--assets` directory under a **versioned** prefix:

```
<uri_prefix>  +  "__dufs_v{dufs-version}__/"  +  <file>
/             +  "__dufs_v0.47.0__/"          +  movi.js     → /__dufs_v0.47.0__/movi.js
```

`GET /movi.js` is **404**. `GET /__dufs_v0.47.0__/movi.js` is 200.

`__ASSETS_PREFIX__` is substituted by `render_html()`, and **only in the HTML string** —
`index.js` and `index.css` are served as-is, so JavaScript cannot see the placeholder.
The prefix is therefore handed to JS through a meta tag:

```html
<meta name="dufs-assets-prefix" content="__ASSETS_PREFIX__">
```

```js
const $meta = document.querySelector('meta[name="dufs-assets-prefix"]');
const prefix = $meta ? $meta.content : "";
script.src = prefix + "movi.js";
```

The prefix is worth relying on for caching: it carries `Cache-Control: immutable` with a
one-year max-age, and a dufs upgrade changes the prefix, which invalidates it for free.

## 3. Page states and the data contract

The shell is one HTML file rendered in three modes, chosen server-side:

| `DATA.kind` | Meaning | Where the frontend handles it |
|---|---|---|
| `Index` | Directory listing | `setupIndexPage()` |
| `Edit` | `?edit` | `setupEditorPage()` (write toolbar if `allow_upload` / `allow_delete`) |
| `View` | `?view` | `setupEditorPage()` (read-only) |

Facts worth remembering (verified against dufs 0.47.0):

- `?view` and `?edit` have **no permission gate** — only read access is enforced.
  `--allow-upload` / `--allow-delete` merely drive which buttons the frontend shows.
- `?view` costs nothing for large files: the server reads 1 KiB and `metadata.len()`.
- `DATA.editable` is false for anything over 4 MiB or not detected as text.
- **`DATA.href` does not contain `uri_prefix`.** Always build file URLs with
  `baseUrl()` (`location.href` minus query/hash), never from `DATA.href`.
- `?edit` and `?view` share the same `if (!DATA.editable)` branch, so anything added
  there applies to both.

## 4. Adding an action button

All row actions are built as HTML strings inside `addPath()` and injected into
`.cell-actions`. To add one:

1. Build the action next to the other `action*` variables, reusing existing helpers
   (`newUrl()`, `extName()`, `baseName()`, `ICONS.*`) instead of new ones.
2. Push it into `actionCell` in the intended order.
3. Check it does not duplicate an existing icon that points at the same URL — dufs
   suppresses its own "View file" icon when `?edit` is available purely to avoid two
   icons with the same destination. Mirror that discipline.

Decision rule for anything that needs to know "which files are videos": an **extension
whitelist is fine for choosing UI**, and is **not** acceptable as a decoder decision.
Extensions do not describe codecs (`.mp4` can be HEVC, `.mkv` can be H.264), and a wrong
guess reproduces the black-frame bug this project exists to fix.

## 5. Secure context gating (WebCodecs)

WebCodecs (`VideoDecoder` / `AudioDecoder`) is `[SecureContext]`. On
`http://<lan-ip>` it does not exist at all, so a wasm-based player silently degrades to
software decoding on the main thread. For 1080p H.264 that is ~6 fps instead of realtime,
and the saturated main thread also slows the player's own `fetch` calls — which makes it
*look* like a network problem.

Rules:

- Before blaming the network, check `window.isSecureContext` and `typeof VideoDecoder`.
- Measure both directions: raw fetch throughput from the page while paused, versus frames
  decoded per second while playing. Supply far above the bitrate + low fps = decode-bound.
- Surface the condition in the UI when it is detectable (`!isSecureContext`), rather than
  letting the user conclude the player is broken.
- `http://localhost` **is** secure; `http://192.168.x.x` is not. A self-signed certificate
  only helps once the client trusts it — an untrusted cert still means an insecure context.
- Do not try to solve this from the page: a web page cannot install a CA, and dufs cannot
  take a key generated in a browser. The supported path is `scripts/gen-tls.sh` (private CA
  + server cert) plus the trust page at `assets/trust/index.html`, which is served by the
  same dufs instance so no file has to be copied between devices. The in-page hint links to
  it; keep that link working (prefix from the meta tag, never hard-coded).
- Serving `ca.crt` is safe — it is a public key. Only `tls/ca.key` / `tls/dufs.key` are
  secrets.

## 6. Third-party loading

- Load heavy third-party assets **lazily**, only on the page that needs them. The
  directory page must stay byte-identical to upstream.
- Keep the loader idempotent with a module-level promise, and provide an `onerror`
  path that degrades to a readable message — never a blank page.
- Custom elements must survive `:not(:defined)` (hide them until upgraded).
- Verify empirically what a library actually does; do not infer it from its README.
  Example: movi-player injects an `@import` for a Google Font into its shadow root,
  and derives its wasm URL from `document.currentScript.src`, which means the injected
  `<script>` must be a real `src` script and `fetch()` must not see credentials in that
  URL.

## 7. Verification recipe

There is no test suite. Verification is manual, against a real dufs binary.

```bash
# dufs binary: GitHub release is fine, proxy if needed
curl -fL -o dufs.tgz https://github.com/sigoden/dufs/releases/download/v0.47.0/dufs-v0.47.0-x86_64-unknown-linux-musl.tar.gz
tar xzf dufs.tgz

# fixtures (kept in /tmp, never committed)
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=25 -t 5 -c:v libx265 -pix_fmt yuv420p -tag:v hvc1 hevc.mkv
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=25 -t 5 -c:v mpeg4 mpeg4.avi

./dufs /tmp/dufs-fixtures --assets "$PWD/assets" --bind 127.0.0.1 --port 5000
```

Checklist per change:

- [ ] directory page: correct actions per file type, no duplicate icons
- [ ] text page: editor still works, no heavy assets requested
- [ ] `?view` on a video: plays, seeks
- [ ] failure path: rename the player JS to force 404 → readable message, download works
- [ ] `?view` over plain HTTP still shows the hint, and its link resolves to `.../trust/`
- [ ] `git status` touches only the intended files

### Gotchas that cost time

| Gotcha | Detail |
|---|---|
| `--assets` has no directory index | The assets handler resolves *files*; a trailing-slash URL for a directory under `--assets` returns `500 Is a directory (os error 21)`. Link `trust/index.html`, never `trust/`. |
| `curl` gets the noscript page | dufs sniffs the UA and serves a server-rendered listing for `curl`/`wget`. Pass a browser UA when checking the HTML shell. `?view` is unaffected. |
| `--auth` syntax | `user:pass@/path:rw`. `user:pass` alone is rejected with `Invalid auth`. |
| Credentials in the URL break the player | `fetch()` cannot construct a request from a URL containing credentials, and movi derives its wasm URL from `document.currentScript.src`. Use the browser's auth cache. |
| Shared browser sessions | When automating, use a dedicated session name so parallel work does not hijack the page. |

## 8. Upstream bookkeeping

`UPSTREAM.md` records the dufs and movi-player versions, the exact local diff against
upstream `assets/`, and the sha256 of both movi files. Any change to either upstream must
update that file in the same commit. The same applies to the files that exist only here:
`scripts/gen-tls.sh` and `assets/trust/` are local additions with no upstream counterpart,
and `UPSTREAM.md` lists them separately.
