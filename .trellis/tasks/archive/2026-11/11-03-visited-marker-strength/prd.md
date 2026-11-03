# PRD — Stronger watched marker + the `index.html` restart rule

## Problem

Two findings from the first deploy of `:visited` dimming (`b05e0b4`):

1. **The marker was too weak to read.** `#24292e` → `var(--text-tertiary)` is a small step on a
   16 px icon, so a list of episodes still could not be scanned for "which did I open". Reported
   by the user as "效果不强" after seeing it live.
2. **The cache-busting was not actually live.** `curl` against the NAS returned an `index.html`
   without any `?v=`, even though the deployed file on disk had it and the css/js on disk were the
   new ones.

## Root cause of (2), measured

| File edited while a dufs instance is running | Served afterwards, without restart |
|---|---|
| `assets/index.html` | **no** — still the copy loaded at startup |
| `assets/index.css` | yes |
| `assets/index.js` | yes |

dufs keeps the rendered `index.html` template in memory. So `bump-assets.sh` output only reaches
browsers after `systemctl restart dufs`, and the earlier "no restart needed" note in the deploy
script was wrong.

## Requirements

R1 — Watched icons fade harder: `#a0a4a8` light / `#6b6b6b` dark. Theme tokens cannot express
this (`--text-secondary` is `#ddd` in the dark scheme; `--text-tertiary` is too close to
`#24292e` in the light one).

R2 — A second, structural cue: a soft chip behind the watched play icon
(`background-color: #e3e8ee` / `#333`). Padding and radius live in the base rule so unvisited and
visited rows occupy identical space — no layout shift when a video gets watched.

R3 — Unvisited rows keep their previous appearance exactly.

R4 — `AGENTS.md`, `README.md` and the deploy script state the restart requirement; the spec gains
the measured table so the next person does not rediscover it.

R5 — No JS, no storage, no markup change; `movi.js` / `movi.wasm` untouched.

## Known limit (documented, not fixed)

The **filename** cannot dim when a video is watched: the name link is `/x.mp4` and the player is
`/x.mp4?view`, and `:visited` matches exact URLs. Only the action link carrying `?view` can hold
the mark. Fixing that would mean repointing the name link (a behaviour change) or JS + storage.

## Acceptance criteria

A1 — Light: watched icon `#a0a4a8` on a `#e3e8ee` chip; unvisited `#24292e`, no chip.

A2 — Dark: watched `#6b6b6b` on `#333`; unvisited `#fff`, no chip.

A3 — Row geometry is identical before and after a video becomes watched (same cell sizes).

A4 — Opening one video changes only that row's icon clip; every other row stays byte-identical.

A5 — Served `index.html` on the deploy target carries `?v=` **after** restarting dufs, and the
`?v=` values equal `date -r` of the two files.

A6 — `movi.js` / `movi.wasm` sha256 unchanged; `node --check assets/index.js` passes.
