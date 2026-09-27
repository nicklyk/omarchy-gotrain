# GoTrain for Omarchy

An Omarchy shell plugin: a bar widget and panel in QML, plus a `gotrain` CLI in
Python. It reads workout data exported from the GoTrain PWA into a local SQLite
archive at `~/.local/share/gotrain/gotrain.db`.

## Constraints that are the product, not preferences

- **Nothing runs on its own.** No daemon, no timer, no background network
  traffic. The README states this unconditionally. The bar icon turning urgent
  is the only nudge the plugin is allowed to make.
- **Python standard library only** in `bin/gotrain`. It ships as a plugin, not
  a package; there is no install step that could fetch dependencies.
- **The archive is the user's only copy** of data they cannot regenerate.
  Anything touching it must be additive and idempotent -- imports merge, never
  replace, and re-importing the same export changes nothing.
- GPL-3.0-or-later.

## Before you finish any change

```bash
tests/run
```

72 checks. Each runs against a throwaway `XDG_DATA_HOME`, so the suite never
reads or writes the real archive. It starts no servers, touches no firewall
rules, and never talks to the running shell. `omarchy-plugin-validate` and
`qmllint` are used when present and skipped with a note when not, so the suite
is still useful off an Omarchy machine -- but a skip is not a pass.

## `main` ships immediately

`omarchy plugin add` clones the default branch and `omarchy plugin update` does
`git fetch origin HEAD` then `merge --ff-only`. So:

- Anything on `main` reaches every user on their next update. There is no
  staging between a push and their desktop.
- **Never force-push or rewrite history on `main`.** A rewritten history stops
  fast-forwarding, and every installed copy then fails to update with a
  misleading "you have local changes" error.

## Packaging facts that fail silently when wrong

- `manifest.json`: `schemaVersion` must be a JSON *number*. A string is rejected
  by the loader without a visible error.
- The id must not begin with `omarchy.` -- that namespace is first-party.
- No symlinks inside the plugin directory; `omarchy-plugin-validate` rejects
  them. The optional `gotrain` symlink on `PATH` lives outside the tree.
- `bin/gotrain` must stay executable. A clone preserves the mode; losing it
  breaks the panel's buttons, which shell out to it.

## Gotchas already paid for

- QML TypeErrors are logged as warnings and **silently swallowed**. Three
  separate "dead control" bugs came from this. After a QML change, reload and
  read the journal rather than assuming a clean render means working code.
- `Util.shellQuote()` is on the `qs.Commons` Util singleton, not on `bar`.
- A bar widget receives a bar *api object*, not the `Bar`. There is no
  `bar.accent`; use `Color.accent`.
- `Qt.darker()` raises contrast on light themes. Use `Util.alpha()` to dim.
- Qt 6.11's `qmllint` exits 255 with no diagnostic on typed function
  declarations, which `IpcHandler` requires. `tests/run` probes for this.
- `omarchy plugin remove` talks to the *running* shell even when `$HOME` points
  elsewhere, so it cannot be sandboxed that way.

## Never

- Never push to `main`. Work on a branch and open a draft PR; merging is the
  owner's decision.
- Never add background network traffic, a daemon or a timer.
- Never commit anything derived from the owner's real archive. Fixtures and
  screenshots use a neutral demo dataset.
