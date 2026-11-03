<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->

## Asset cache busting (must read before editing `assets/`)

dufs serves everything under `--assets` with `Cache-Control: public, max-age=31536000, immutable`
and ignores query strings, so a deployed `index.css` / `index.js` keeps running from cache until
its URL changes. `assets/index.html` is `no-cache`, which is why it carries the version query.

**After editing `assets/index.css` or `assets/index.js`, run `./bump-assets.sh` before committing.**
It bakes each file's mtime into `assets/index.html` as `?v=<mtime>`. Forgetting it means the change
silently does nothing in every browser that has visited before — no error, no hint, just the old
code.

Do not version `index.html`, `movi.js`, `movi.wasm`, `favicon.ico` or `trust/*`: they change only
when syncing upstream, and their long cache is the point.

dufs reads `index.html` **once, at startup** (`index.css` / `index.js` are per-request), so a bump
only takes effect after `systemctl restart dufs` on the deploy target. A CSS/JS-only change needs
no restart.
