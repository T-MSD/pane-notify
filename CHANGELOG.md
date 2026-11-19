# Changelog

## 0.1.0 (unreleased)

First release.

- Badge on the window, bell in the status bar and a desktop notification when a
  long command finishes (zsh, bash) or a coding agent is waiting for input.
- Sidebar listing unseen notifications, toggled with `prefix + a`; click an
  entry to open its window, `q` or Ctrl-C to close it.
- Keyboard navigation in the sidebar: opening it focuses it, arrow keys select
  an entry, highlighted with a shade of the terminal's background, `Enter`
  opens its window and `x` removes it. `@pane-notify-sidebar-selected` sets the
  highlight colour instead.
- Floating sidebar in zoomed windows on tmux 3.8+.
- Closing the sidebar restores the widths of the window's columns.
- Desktop notifications over OSC 9, OSC 777 or OSC 99.
- Claude Code hooks shipped as a Claude Code plugin.
- Codex CLI hooks (`Stop`, `PermissionRequest`, `UserPromptSubmit`), with an
  example `~/.codex/hooks.json`.
