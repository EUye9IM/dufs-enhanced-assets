# PRD — Player seek controls: arrow keys + swipe

## Problem

The player page (`?view` on a video) cannot be seeked without aiming at the progress bar:

- **PC**: `←` / `→` do nothing. The user expects a small jump per press, the way every other
  video site behaves.
- **Mobile**: dragging the progress bar works, but the bar is ~24 px tall at the bottom of a
  phone screen — a hard target while holding the device. The user expects to swipe across the
  picture itself.

`movi-player` implements both, and `assets/movi.js` is byte-identical to upstream — the
capability is switched off, not missing.

### Measured state of the bundled build

`movi.js` gates three seek channels behind the `fastseek` attribute
(`applyFastSeek`, default when the attribute is absent: all three off):

| Channel | Behaviour in `movi.js` | Gated by |
|---|---|---|
| `keys` | `←`/`→` = `performRelativeSeek()` ±10 s, chained within 1 s (10 → 20 → 30 …), `Ctrl/Cmd+←/→` = ±1 frame | `_fastSeekModes.keys` |
| `gestures` | horizontal drag on the picture = `dx / width × 90` s continuous seek with OSD `time / duration`; double-tap left 30 % / right 30 % = ∓10 s; double-tap centre = fullscreen | `_fastSeekModes.gestures` |
| `buttons` | shows the ±10 s buttons in the control bar | `_fastSeekModes.buttons` |

Measured on the current page (CDP, 300 s fixture, `fastseek` absent):

| Action | `currentTime` |
|---|---|
| `fastseekModes` | `""` |
| `→` (player focused) | 30.57 → 31.29 — playback advance only, **no jump** |
| progress-bar touch drag 20 % → 80 % | 240.8 s of 300 — already works |
| swipe on picture (+120 px of 1440) | no change |

With `fastseek="all"` the same three actions measured `30.67 → 41.25 → 51.10` (keys chaining),
`+7.5 s` (swipe), `30 → 40` / `30 → 20` (double-tap).

## Requirements

R1 — On the player page, `←` / `→` seek ∓10 s, and repeated presses accumulate rather than
restart from the same point.

R2 — `Ctrl`/`Cmd` + `←`/`→` keep movi's frame-step behaviour (no regression, no custom logic).

R3 — On touch devices, a horizontal drag across the picture seeks continuously and shows the
target time while dragging.

R4 — The ±10 s buttons must **not** be added to the control bar: the bar is already at its width
limit on a phone, and the seek is reachable by keyboard, swipe and double-tap.

R5 — Progress-bar click/drag keeps working exactly as it does today (mouse and touch).

R6 — Typing in a text field never seeks: `movi.js` already guards `INPUT`/`TEXTAREA`/`SELECT`.

R7 — `movi.js` and `movi.wasm` stay byte-identical to upstream.

R8 — Directory pages, text `?view` pages, `?edit` pages and binary `?view` pages are unaffected
(they never mount the player).

## Out of scope

- Custom hotkeys, remappable keys, per-user preferences.
- ±10 s control-bar buttons (R4).
- Changing the swipe-to-seconds ratio (90 s per full width) or the ±10 s step.
- Autofocusing the player on page load — see the note below.

## Note: keyboard focus

`movi.js` listens for `keydown` on the element itself, and focuses itself on any `pointerdown`
inside it, so pressing `→` after clicking the picture, the play button or the progress bar works.
Pressing `→` on a freshly loaded page (nothing clicked yet, `activeElement === BODY`) does
nothing — measured: `30 → 30`.

We deliberately do **not** autofocus on mount: a script-triggered focus on page load can raise a
focus ring and steal focus from the browser chrome. Clicking once inside the player is the
expected first interaction on a video page, and it is what the acceptance check uses.

## Acceptance criteria

A1 — `document.querySelector('movi-player').fastseekModes === "keys gestures"`.

A2 — With the player focused, three consecutive `→` presses advance `currentTime` by ≈10 s each
(cumulative ≈+30 s), and three `←` presses bring it back.

A3 — `Ctrl+→` advances by one frame interval (≈1/24 s), not 10 s.

A4 — A synthetic horizontal touch drag across the picture changes `currentTime` and the OSD
shows `mm:ss / mm:ss`; the same drag released does not toggle fullscreen.

A5 — A synthetic touch drag on the progress bar still seeks (no regression), and the control bar
still contains no `.movi-seek-backward` / `.movi-seek-forward` buttons (they stay `display:none`).

A6 — `sha256sum assets/movi.js assets/movi.wasm` equal the values recorded in `UPSTREAM.md`.

A7 — `node --check assets/index.js` passes; directory and text `?view` pages render unchanged.
