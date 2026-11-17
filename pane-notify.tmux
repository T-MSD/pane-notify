#!/usr/bin/env bash
# Options (set before this file runs). Colours take any tmux colour or a
# format such as '#{@my_colour}'.
#   @pane-notify-color-{done,failed,waiting}  badge colours (green, red, yellow)
#   @pane-notify-icon-{done,failed,waiting}   badge glyphs (●)
#   @pane-notify-color-status                 bell colour (yellow)
#   @pane-notify-icon-status                  bell glyph, with its trailing space ("🔔 ")
#   @pane-notify-sidebar-{text,subtle,muted,rule}
#                                             sidebar colours (default, default,
#                                             brightblack, brightblack)
#   @pane-notify-key                          prefix key for the sidebar (a); off = none
#   @pane-notify-auto-format                  on = add the badge and bell to the
#                                             status formats (on)
#   @pane-notify-sidebar                      on | off (record sidebar entries)
#   @pane-notify-bar-max                      notifications listed at once (10)
#   @pane-notify-sidebar-width                sidebar columns (30, at most a third of the window)
#   @pane-notify-desktop                      unfocused | always | off
#   @pane-notify-desktop-protocol             osc9 | osc777 | osc99
#   @pane-notify-when-visible                 on = notify even when watching

get_opt() {
  local value
  value="$(tmux show-option -gqv "$1")"
  printf '%s' "${value:-$2}"
}

# "tmux 3.2a" -> 302; development builds ("next-3.9", "master") count as new.
tmux_version() {
  local v major minor
  v="$(tmux -V)"
  v=${v#tmux }
  v=${v#next-}
  case $v in [0-9]*.[0-9]*) ;; *) echo 9999; return ;; esac
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%[!0-9]*}
  echo $((major * 100 + minor))
}

version="$(tmux_version)"
if [ "$version" -lt 302 ]; then
  tmux display-message "pane-notify needs tmux 3.2 or later ($(tmux -V))"
  exit 0
fi
# Floating panes that stay above a zoomed pane (new-pane -A).
if [ "$version" -ge 308 ]; then
  tmux set-option -g @pane_notify_floating 1
else
  tmux set-option -gu @pane_notify_floating
fi

# U+25CF and U+1F514 as UTF-8 bytes.
circle=$'\xe2\x97\x8f'
bell=$'\xf0\x9f\x94\x94 '

# Written to internal options so the user-facing ones are never overwritten.
badge=""
for spec in "done:green" "failed:red" "waiting:yellow"; do
  IFS=: read -r state default_colour <<<"$spec"
  c="$(get_opt "@pane-notify-color-$state" "$default_colour")"
  i="$(get_opt "@pane-notify-icon-$state" "$circle")"
  tmux set-option -g "@pane_notify_color_$state" "$c"
  tmux set-option -g "@pane_notify_icon_$state" "$i"
  badge="${badge}#{?#{==:#{@pane_notify},${state}}, #[fg=${c}]${i},}"
done
tmux set-option -g @pane-notify-badge "$badge"

c="$(get_opt @pane-notify-color-status yellow)"
i="$(get_opt @pane-notify-icon-status "$bell")"
tmux set-option -g @pane-notify-status "#{?#{@pane_notify_count},#[fg=${c}]${i}#[default],}"

if [ "$(get_opt @pane-notify-auto-format on)" = on ]; then
  for o in window-status-format window-status-current-format; do
    v="$(tmux show-option -gwv "$o")"
    case $v in *@pane-notify-badge*) ;; *) tmux set-option -gw "$o" "$v#{E:@pane-notify-badge}" ;; esac
  done
  v="$(tmux show-option -gv status-right)"
  case $v in *@pane-notify-status*) ;; *) tmux set-option -g status-right "#{E:@pane-notify-status}$v" ;; esac
fi

here="$(cd "$(dirname "$0")" && pwd)"
key="$(get_opt @pane-notify-key a)"
[ "$key" = off ] || tmux bind-key "$key" run-shell -b "'$here/scripts/notify.sh' sidebar-toggle '#{client_name}'"

# A background session's current window can change unseen (e.g. kill-window).
clear="if-shell -F '#{session_attached}' 'set-option -wu @pane_notify'"
for hook in session-window-changed client-session-changed pane-focus-in; do
  tmux set-hook -g "${hook}[77]" "$clear"
done

# Skipped while @pane_notify_busy is set: the plugin's own kills need no new
# render.
follow="if-shell -F '#{?#{@pane_notify_busy},,#{@pane_notify_bar_active}}' { run-shell -b \"'$here/scripts/notify.sh' bar-refresh\" }"
# after-resize-pane: zoom toggles. pane-exited/after-kill-pane: a window left
# with only its sidebar.
for hook in session-window-changed client-session-changed client-focus-in window-unlinked after-resize-pane \
            pane-exited after-kill-pane; do
  tmux set-hook -g "${hook}[78]" "$follow" 2>/dev/null
done
