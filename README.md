<div align="center">

# `💻 tsession`

<br /><br />

<img src="https://github.com/user-attachments/assets/4e16e631-6eef-4fbd-9da0-c8350886cc44" width="100%" />
<img src="https://github.com/user-attachments/assets/7311c841-6815-4e87-8a3a-a24a14f294a0" width="100%" />

<br /><br />

</div>

A lightweight tmux session manager: prompt-based session switching/creation,
an interactive saved-session picker, and snapshot save/restore (window order,
names, layouts, working directories, running commands).

## Features

- **Switch or create** — press a key, type a name; jump to the session or
  create it on the fly.
- **Saved-session menu** — popup built from the save file, not live sessions:
  `●` = alive (switch), `○` = saved only (restore + switch). With fzf:
  `Enter` switch/restore, `D` delete snapshot, `X` kill live, `C` clone,
  `R` rename, `?` live preview of windows/panes.
- **Save / restore snapshots** — dump sessions, windows, panes, cwds and
  running commands into a single file, then rebuild everything after a reboot
  or `kill-server` — all at once or one session. Optional scrollback capture.
- **Zero dependencies** beyond tmux plus standard `base64` and `ps`.
  No Python; fzf optional.

## Key bindings (prefix table)

| Keys              | Action                                                   |
| ----------------- | -------------------------------------------------------- |
| `Prefix + T`      | Prompt for a session name → switch or create             |
| `Prefix + Ctrl-g` | Menu of **saved** sessions (restore-or-switch)           |
| `Prefix + Ctrl-s` | Save the **current** session (merged into the save file) |
| `Prefix + Ctrl-r` | Restore all sessions from the save file                  |

## Installation

**TPM (recommended):**

```tmux
set -g @plugin 'Nighty3098/tsession'
run '~/.tmux/plugins/tpm/tpm'
```

Reload tmux config, then `Prefix + I` inside tmux to install.

**Manual:**

```tmux
set -g @tsession-menu-key 'C-g'
run-shell /path/to/tsession/tsession.plugin.tmux
```

> Do **not** load with `tmux source-file` — it's a bash script executed via
> `run-shell`.

## Options

| Option                      | Default                 | Description                                                                                |
| --------------------------- | ----------------------- | ------------------------------------------------------------------------------------------ |
| `@tsession-key`             | `T`                     | Prompt for session name (switch/create)                                                    |
| `@tsession-menu-key`        | `C-g`                   | Menu of saved sessions                                                                     |
| `@tsession-save-key`        | `C-s`                   | Save snapshot                                                                              |
| `@tsession-restore-key`     | `C-r`                   | Restore snapshot                                                                           |
| `@tsession-save-path`       | `~/.tmux-tsession.save` | Snapshot file (`~` is expanded)                                                            |
| `@tsession-kill-existing`   | `off`                   | `on` = entering an existing name kills it and creates a fresh session instead of switching |
| `@tsession-history-lines`   | `0`                     | Scrollback lines captured per pane on save (`0` = off, e.g. `100`)                         |
| `@tsession-restore-cmds`    | `on`                    | `off` = restore shells only, never re-run saved commands                                   |
| `@tsession-restore-history` | `on`                    | `off` = skip re-printing captured scrollback on restore                                    |
| `@tsession-fzf-preview`     | `on`                    | `off` = disable the windows/panes preview in the fzf picker                                |

Options must be set **before** the `run`/`run-shell` line.

## Usage

- **Switch or create:** `Prefix + T`, type a name, Enter. Empty cancels; `.`
  and `:` become `_` (tmux forbids them in names).
- **Saved-session menu:** `Prefix + Ctrl-g`. Requires tmux ≥ 3.2. Without fzf
  it falls back to a static `display-menu` with per-session actions. If no
  save file yet, it tells you to press `Prefix + Ctrl-s` first.
- **Save:** `Prefix + Ctrl-s` snapshots the current session only (idempotent
  merge). `scripts/save.sh` with no name saves **all** live sessions.
- **Restore:** `Prefix + Ctrl-r` rebuilds everything; same-named live sessions
  are killed, windows recreated at their indexes, splits/layouts reapplied,
  cwd restored, saved commands re-typed, active window/pane re-selected.
  `scripts/restore.sh [path] [session]` restores one session and switches to it.

### Example configuration

```tmux
set -g @plugin 'Nighty3098/tsession'

set -g @tsession-key           'C-n'     # switch-or-create prompt
set -g @tsession-menu-key      'C-g'     # saved-session menu (default)
set -g @tsession-save-key      'C-s'     # save snapshot
set -g @tsession-restore-key   'C-r'     # restore all
set -g @tsession-save-path     '~/.local/share/tsession/sessions.save'
set -g @tsession-kill-existing 'on'
set -g @tsession-history-lines '100'

run '~/.tmux/plugins/tpm/tpm'
```

