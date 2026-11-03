# PRD — Dim already-opened rows with `:visited`

## Problem

The file list gives no way to tell which videos have already been opened. Re-opening a video you
finished two days ago looks exactly like opening a new one.

The cheap, storage-free answer is the browser's own link history: the play action is
`<a href="<file>?view">`, so opening it marks that exact URL visited. It survives reloads, needs
no JavaScript and no per-device state of our own. `:visited` was reviewed against the heavier
alternatives (localStorage / IndexedDB / a server-side record) and chosen explicitly by the user
for that reason — the goal is "which did I open", not playback progress.

## Requirements

R1 — An opened video's ▶ play icon renders dimmer than an unopened one, in both colour schemes.

R2 — A visited filename link (`.path a`) is dimmed the same way, which is the classic
"visited link" behaviour.

R3 — Unvisited rows must look exactly as before this change: the icon keeps `--svg-primary`
(`#24292e` light / `#fff` dark), no new borders, backgrounds or spacing.

R4 — Zero storage, zero JS, no new markup. CSS only, inside `assets/index.css`.

R5 — No `movi.js` / `movi.wasm` change (both stay byte-identical to upstream).

R6 — `bump-assets.sh` runs as part of the change, so the CSS actually reaches browsers.

## Constraints discovered in Chrome

| Constraint | Consequence |
|---|---|
| `:visited` may only change colour-type properties (`color`, `background-color`, `border-*-color`, `outline-color`, `fill`, `stroke`) | no `opacity`, no `content:` — a ✓ badge is impossible without JS |
| Descendants and pseudo-elements do not receive visited styles | `a:visited svg { fill }` is dead; the colour must arrive by inheritance |
| `getComputedStyle()` returns the unvisited value | the state is unreadable from JS, so verification must be visual |

## Implementation sketch

```css
.cell-actions a[href$="?view"] { color: var(--svg-primary) }      /* R3: preserve the old look */
.cell-actions a[href$="?view"] svg { fill: currentColor }         /* colour reaches the icon */
.cell-actions a[href$="?view"]:visited { color: var(--text-tertiary) }
.path a:visited { color: var(--text-tertiary) }
```

`--text-tertiary` rather than `--text-secondary`: it is the token that reads as dimmer in **both**
schemes (light `#24292e`→`#586069`, dark `#fff`→`#586069`). `--text-secondary` is `#ddd` in the
dark theme, which nearly disappears on black.

## Out of scope

- Storage-backed state (localStorage / IndexedDB): no "continue watching", no ✅ badge, no
  cross-device marks. Explicitly declined for now.
- Enabling `movi`'s `resume` attribute (would add a resume prompt we did not ask for).
- Making the whole row dim: `:visited` cannot style ancestors, and `:has()` with `:visited` does
  not match.

## Acceptance criteria

A1 — Light scheme: after opening one video and reloading the list, that row's play icon renders
`#586069` while the untouched row stays `#24292e`.

A2 — Dark scheme (`prefers-color-scheme: dark`): visited `#586069`, unvisited `#fff`.

A3 — Every other row's icon is byte-identical before and after the visit (screenshot clip hashes).

A4 — The filename link of a visited file is dimmed; the unvisited one is unchanged.

A5 — Directory page, text `?view`, `?edit`, and the player page are visually unchanged.

A6 — `index.html` carries a fresh `index.css?v=` value; `movi.js` / `movi.wasm` sha256 unchanged.
