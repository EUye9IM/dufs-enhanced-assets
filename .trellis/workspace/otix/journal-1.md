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
