# pane-notify

Know when something in another tmux window needs you.

When a long-running command finishes, or a coding agent
([Claude Code](https://claude.com/claude-code), [Codex CLI](https://developers.openai.com/codex))
stops to wait for input or permission, pane-notify:

- puts a coloured **badge** (●) on that window in the status bar: green when a
  command succeeded, red when it failed, yellow when an agent is waiting;
- shows a **bell** in the status bar until you have seen every notification;
- keeps a **sidebar** you can open with `prefix + a`, listing what happened
  where; click an entry, or select it with the arrow keys and press Enter, to
  jump to its window;
- sends a **desktop notification** when your terminal is not focused.

Nothing is reported for the window you are looking at. A badge and its entry
clear as soon as you open the window.

## Requirements

- tmux 3.2 or later. In zoomed windows the sidebar floats above the zoomed
  pane on tmux 3.8+; on older versions it stays hidden until you unzoom.
- bash 3.2 or later (for the scripts; your shell can be zsh or bash).
- `jq`, for the Claude Code and Codex CLI hooks.

## Install

### With [TPM](https://github.com/tmux-plugins/tpm)

```tmux
set -g @plugin 'T-MSD/pane-notify'
```

Press `prefix + I` to install.

### By hand

```sh
git clone https://github.com/T-MSD/pane-notify ~/.tmux/plugins/pane-notify
```

```tmux
run-shell ~/.tmux/plugins/pane-notify/pane-notify.tmux
```

Load it after your theme or anything else that sets `status-right` and the
window-status formats: pane-notify adds its badge and bell to whatever is
there at the time (see [Status bar](#status-bar)).

### Shell hook

The shell tells tmux when a command finishes. Add one line to your shell's rc
file, after anything that sets `PROMPT_COMMAND` or loads bash-preexec:

```sh
# ~/.zshrc
source ~/.tmux/plugins/pane-notify/pane-notify.zsh

# ~/.bashrc
source ~/.tmux/plugins/pane-notify/pane-notify.bash
```

Shells that were already open need to be restarted (`exec zsh`, `exec bash`).

| Variable | Default | |
|---|---|---|
| `PANE_NOTIFY_MIN_SECONDS` | `10` | Only commands that ran at least this long notify. |
| `PANE_NOTIFY_IGNORE` | editors, pagers, `ssh`, `top`, … | Programs that never notify. Wrappers such as `sudo -u user`, `env X=1` and `command` are looked through. |

Commands stopped with Ctrl-C or Ctrl-Z never notify.

### Claude Code

Either install the hooks as a Claude Code plugin:

```
/plugin marketplace add T-MSD/pane-notify
/plugin install pane-notify@pane-notify
```

or add the hooks from [`examples/claude-settings.json`](examples/claude-settings.json)
to `~/.claude/settings.json`. Use one or the other, not both.

Claude Code has to run inside tmux. The hooks fire when Claude finishes a turn
(`Stop`), asks for permission or input (`Notification`), and clear the window
when you send a prompt (`UserPromptSubmit`).

### Codex CLI

Copy [`examples/codex-hooks.json`](examples/codex-hooks.json) to
`~/.codex/hooks.json`, or merge its `hooks` into the one you have. Then run
`/hooks` in Codex and trust them: Codex skips hooks it has not been told to
trust, and again after they change.

Codex has to run inside tmux. The hooks fire when Codex finishes a turn
(`Stop`), asks for approval (`PermissionRequest`), and clear the window when you
send a prompt (`UserPromptSubmit`).

Codex can send its own desktop notifications (`tui.notifications` in
`~/.codex/config.toml`). Turn them off, or `@pane-notify-desktop off`, to avoid
getting two.

## Usage

| | |
|---|---|
| `prefix + a` | Open the sidebar and focus it, or close it. |
| Click an entry | Open its window and remove the entry. |
| `↑`, `↓` in the sidebar | Select an entry. |
| `Enter` in the sidebar | Open the selected entry's window and remove the entry. |
| `x` in the sidebar | Remove the selected entry. |
| `q`, Ctrl-C in the sidebar | Close the sidebar. |

The sidebar is a 30-column split on the right of the window you are looking
at, and follows you between windows. It closes by itself when nothing is left.

While the sidebar is the focused pane, the selected entry is highlighted. By
default the highlight is a shade of your terminal's background, lighter on a
dark theme and darker on a light one, so it shows on any colour scheme. The
sidebar asks the terminal for its background (OSC 11), which tmux answers from
the pane's style or, on tmux 3.4+, from the terminal itself. When nothing
answers, the highlight falls back to reverse video. Set
`@pane-notify-sidebar-selected` to a colour to choose it yourself.

The highlight follows pane focus only with `set -g focus-events on`; without
it, it appears at the first arrow key and stays until the sidebar is next
redrawn.

Entries stay until you open their window, click them, remove them, or the
window closes. A newer notification from the same window replaces the older
one.

## Options

Set these in `~/.tmux.conf` before the plugin loads. Colours accept any tmux
colour (`red`, `brightblack`, `colour208`, `#ff5050`) or a format such as
`#{@my_theme_colour}`.

| Option | Default | |
|---|---|---|
| `@pane-notify-color-done` | `green` | Badge colour for a command that succeeded. |
| `@pane-notify-color-failed` | `red` | Badge colour for a command that failed. |
| `@pane-notify-color-waiting` | `yellow` | Badge colour for an agent waiting. |
| `@pane-notify-icon-done`, `-failed`, `-waiting` | `●` | Badge glyphs. |
| `@pane-notify-color-status` | `yellow` | Bell colour. |
| `@pane-notify-icon-status` | `🔔 ` | Bell glyph, including any spacing after it. |
| `@pane-notify-sidebar-text` | `default` | Sidebar: window names. |
| `@pane-notify-sidebar-subtle` | `default` | Sidebar: what happened. |
| `@pane-notify-sidebar-muted` | `brightblack` | Sidebar: the command line. |
| `@pane-notify-sidebar-rule` | `brightblack` | Sidebar: its left edge when floating. |
| `@pane-notify-sidebar-selected` | `auto` | Sidebar: background of the selected entry; `auto` shades the terminal's background. |
| `@pane-notify-sidebar-width` | `30` | Sidebar width, at most a third of the window. |
| `@pane-notify-bar-max` | `10` | Notifications kept at once. |
| `@pane-notify-key` | `a` | Prefix key for the sidebar; `off` for none. |
| `@pane-notify-sidebar` | `on` | `off` hides the sidebar; badges, the bell and desktop notifications stay. |
| `@pane-notify-auto-format` | `on` | Add the badge and bell to the status bar. |
| `@pane-notify-desktop` | `unfocused` | `unfocused`, `always` or `off`. |
| `@pane-notify-desktop-protocol` | `osc9` | `osc9`, `osc777` or `osc99`. |
| `@pane-notify-when-visible` | `off` | `on` notifies even for the window you are looking at. |

Example:

```tmux
set -g @pane-notify-color-waiting '#{@my_accent}'
set -g @pane-notify-icon-status '󰂚  '     # Nerd Font bell
set -g @pane-notify-desktop-protocol osc777
run-shell ~/.tmux/plugins/pane-notify/pane-notify.tmux
```

## Status bar

With `@pane-notify-auto-format on`, the plugin appends `#{E:@pane-notify-badge}`
to `window-status-format` and `window-status-current-format`, and puts
`#{E:@pane-notify-status}` at the start of `status-right`. It skips any format
that already mentions them, so you can place them yourself:

```tmux
setw -g window-status-format ' #I #W#{E:@pane-notify-badge} '
set -g status-right '#{E:@pane-notify-status}%H:%M '
```

A theme that sets these formats after the plugin loads replaces them; load
pane-notify last, or place the two formats in the theme yourself.

## Desktop notifications

The notification is written straight to your terminal as an escape sequence,
so it also works over SSH and needs no `allow-passthrough`. Pick the sequence
your terminal understands:

| Protocol | Terminals (check your terminal's docs) |
|---|---|
| `osc9` | iTerm2, Ghostty, WezTerm, kitty |
| `osc777` | Ghostty, WezTerm, foot, rxvt-unicode (with its notify extension) |
| `osc99` | kitty, recent foot |

macOS Terminal.app does not support any of them.

OSC 9 carries only the message; terminals that support it add their own
heading, usually the terminal's title. To make that the tmux window's name:

```tmux
set -g set-titles on
set -g set-titles-string '#W'
```

With `osc777` and `osc99` the window name is sent as the title.

## How it works

- Each notification is one global tmux option, `@pane_notify_entry_<n>`. The
  badge (`@pane_notify` on each window) and the bell (`@pane_notify_count`)
  are derived from these entries every time they change.
- tmux hooks are added at index `[78]` (refreshing the badges, bell and
  sidebar) of `session-window-changed`, `client-session-changed`,
  `client-focus-in`, `window-unlinked`, `after-resize-pane`, `pane-exited` and
  `after-kill-pane`. Other plugins using that index would replace them.
- Updates are serialised with a lock directory in `$TMPDIR`.

## Troubleshooting

- **No notification after a long command:** the shell was started before the
  hook was added to its rc file. Restart it.
- **No badge or bell:** something set the status formats after the plugin
  loaded. See [Status bar](#status-bar).
- **No desktop notification:** your terminal may not support the protocol, it
  was focused (`@pane-notify-desktop always` to test), the terminal lacks
  notification permission, or Do Not Disturb / Focus is on.
- **Nothing from Claude Code or Codex:** check that `jq` is installed and the
  agent is running inside tmux. For Codex, check `/hooks` lists the hooks as
  trusted.

## Development

```sh
tests/run.sh
```

The tests start private tmux servers (`tmux -L`), so they never touch yours.
They need zsh and jq for the shell and agent hook sections, which are
skipped otherwise. CI runs them on tmux 3.2a, 3.4 and the latest release, plus
`shellcheck`.

## License

MIT
